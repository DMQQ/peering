import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

extension CursorOverlay {
    /// Draws nothing, leaving the frame untouched, on every failed check: a half-drawn frame is worse than a pointer where the system put it. The lock is held for the draw, so a preference change on the main actor waits a few hundred microseconds.
    func draw(into buffer: CVPixelBuffer, geometry: FrameGeometry) {
        // Cleared up front: whatever this call draws is what an idle frame would have to undo. The timeline high-water mark goes too, since a restarted stream reports from an unrelated clock.
        guard lock.withLock({ () -> Bool in
            drawnTip = nil
            scratch?.lastSentTime = .invalid
            return enabled
        }) else { return }

        // Checked exactly: in BGRA plane 0 is the whole picture and luma written there is a band of colour.
        guard CVPixelBufferIsPlanar(buffer),
              CVPixelBufferGetPlaneCount(buffer) > 1,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            report("the frame is not in the pixel format this draws into")
            return
        }

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            report("the frame's pixels could not be locked")
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              CVPixelBufferGetBaseAddressOfPlane(buffer, 1) != nil
        else {
            report("the frame has no planes this can read")
            return
        }
        let plane = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard width > 0, height > 0, stride >= width else {
            report("the frame's luma plane has no usable size")
            return
        }

        // Ahead of the pointer guards: this is the last moment the frame is in hand and free of a pointer, with no second chance until the stream delivers another.
        refresh(from: buffer, geometry: geometry)

        // In the global point space frames describe, the same as InputTransform posts into. Nil is not worth drawing through: a stale position is a wrong pointer.
        guard let pointer = CGEvent(source: nil)?.location else {
            report("the pointer's position could not be read")
            return
        }

        // Inverts the mapping the client's own input goes through, so a tap lands where this draws.
        guard let transform = geometry.inputTransform else {
            report("the frame does not say where its content sits on screen")
            return
        }
        lock.withLock { lastTransform = transform }

        let position = transform.normalizedPoint(fromGlobal: pointer)
        // Outside 0...1 is another display or beside a captured window: ordinary, not a failure.
        guard position.x >= 0, position.x <= 1, position.y >= 0, position.y <= 1 else { return }

        let size = lock.withLock { chosenSize }
        // The luma plane's own dimensions: for 420v it is the unsubsampled plane and has a stride.
        let scale = CGFloat(height) * size.fractionOfHeight
        guard scale.isFinite, scale >= 1 else {
            report("the frame is too small for a pointer to be drawn at any size")
            return
        }

        let tip = CGPoint(x: position.x * CGFloat(width), y: position.y * CGFloat(height))

        lock.withLock {
            for pass in passes {
                rasterize(
                    pass,
                    tip: tip,
                    scale: scale,
                    plane: plane,
                    stride: stride,
                    width: width,
                    height: height
                )
            }
            // Recorded only once the pointer is in the picture; every early return leaves this nil.
            drawnTip = CGPoint(x: tip.x.rounded(), y: tip.y.rounded())
        }
    }

    /// An idle sample is not a frame: it may carry no image buffer, so the picture is this object's own, kept from a delivered frame. The last frame's buffer cannot be drawn into (a pool ScreenCaptureKit reuses, still read by VideoToolbox: a torn picture), so drawing goes into an owned buffer and acquire(_:) asks whether the encoder is finished with it.
    /// Disabled in ``CapturePipeline``: invented frames broke the decoder's reference chain.
    /// A changed screen pays for the whole picture (nothing knows which pixels changed). A delivered frame closes this path for one sample, so on a still screen one frame in a run pays and the rest cost two pointer-sized rectangles.
    func redraw(_ sample: IdleSample) -> CapturedFrame? {
        guard lock.withLock({ enabled }) else { return nil }

        // The same question as draw(into:geometry:), with the last frame's answer standing in when this sample has none.
        guard let transform = lock.withLock({ sample.geometry.inputTransform ?? lastTransform }) else {
            return nil
        }

        guard let pointer = CGEvent(source: nil)?.location else {
            report("the pointer's position could not be read")
            return nil
        }
        let position = transform.normalizedPoint(fromGlobal: pointer)
        guard position.x >= 0, position.x <= 1, position.y >= 0, position.y <= 1 else { return nil }

        var refusal: String?
        let frame = lock.withLock { () -> CapturedFrame? in
            guard var scratch = self.scratch, scratch.holdsPicture else { return nil }

            if sample.duration.isValid, sample.duration.value > 0 {
                scratch.lastInterval = sample.duration
            }
            guard let time = Self.timestamp(
                reported: sample.presentationTime,
                after: scratch.lastSentTime,
                interval: scratch.lastInterval
            ) else {
                return nil
            }
            scratch.lastSentTime = time

            let width = scratch.width
            let height = scratch.height
            let size = chosenSize
            let scale = CGFloat(height) * size.fractionOfHeight
            guard scale.isFinite, scale >= 1 else { return nil }

            // Nothing moved, so nothing to send: samples arrive on schedule regardless, and a frame with the pointer unchanged is one the client is already looking at. This is also the rate limit; acquire(_:) caps it further at what the encoder can take.
            let tip = CGPoint(
                x: (position.x * Double(width)).rounded(),
                y: (position.y * Double(height)).rounded()
            )
            guard tip != drawnTip else { return nil }

            // Only when the screen has just been still: a changing screen carries the pointer in its own frames, and an idle frame between two adds a whole-picture copy for nothing. Checked here because it is the copy being avoided.
            if scratch.pictureArrived {
                scratch.pictureArrived = false
                self.scratch = scratch
                return nil
            }
            scratch.pictureArrived = false

            guard let region = Self.region(bounds(tip: tip, scale: scale), width: width, height: height),
                  region.width <= scratch.patchWidth, region.height <= scratch.patchHeight
            else {
                refusal = "the pointer is larger than the region kept for taking it back out"
                return nil
            }

            guard let buffer = acquire(scratch) else { return nil }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

            guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
                refusal = "the buffer set aside for idle frames has no luma plane to write"
                return nil
            }
            let destination = destinationBase.assumingMemoryBound(to: UInt8.self)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            guard destinationStride >= width, CVPixelBufferGetHeightOfPlane(buffer, 0) == height else {
                refusal = "the buffer set aside for idle frames is not the size of the frame"
                return nil
            }

            // Which pool buffer, by where its luma plane lives: stable while the surface exists, and the pool holds surfaces by not aging them out. See makeScratch(width:height:geometry:).
            if scratch.buffers.count >= Scratch.bufferLimit { scratch.buffers.removeAll() }
            let index = scratch.buffers.firstIndex { $0.planeBase == destinationBase }
            var state: Scratch.Buffer
            if let index {
                state = scratch.buffers[index]
            } else {
                state = Scratch.Buffer(
                    planeBase: destinationBase,
                    stride: destinationStride,
                    patch: [UInt8](repeating: 0, count: scratch.patchWidth * scratch.patchHeight),
                    patchRegion: nil,
                    generation: 0
                )
            }

            // Rows that are not the ones the saved region was taken at would land in the wrong
            // places, so the region is forgotten and the whole picture goes in.
            if state.stride != destinationStride {
                state.patchRegion = nil
                state.generation = 0
                state.stride = destinationStride
            }

            // An older picture must be copied whole (nothing knows which pixels changed), and the saved region goes with it: putting it back after the new picture is a smudge.
            if state.generation != scratch.generation {
                guard Self.copyPicture(from: scratch.picture, into: buffer) else { return nil }
                state.patchRegion = nil
                state.generation = scratch.generation
            }
            if let previous = state.patchRegion {
                restore(previous, from: state.patch, into: destination, stride: destinationStride)
                state.patchRegion = nil
            }

            save(region, from: destination, stride: destinationStride, into: &state.patch)
            state.patchRegion = region

            if let index {
                scratch.buffers[index] = state
            } else {
                scratch.buffers.append(state)
            }

            for pass in passes {
                rasterize(
                    pass,
                    tip: tip,
                    scale: scale,
                    plane: destination,
                    stride: destinationStride,
                    width: width,
                    height: height
                )
            }

            self.scratch = scratch
            drawnTip = tip

            return CapturedFrame(
                pixelBuffer: buffer,
                presentationTime: time,
                duration: sample.duration,
                geometry: scratch.geometry
            )
        }

        if let refusal { report(refusal) }
        return frame
    }

    /// Strictly forward: VideoToolbox fails the whole stream on a repeated timestamp. An idle sample may carry no time or repeat the last frame's, so its answer is used only when ahead, else the frame interval is added to the last sent.
    private static func timestamp(reported: CMTime, after last: CMTime, interval: CMTime) -> CMTime? {
        let step = interval.isValid && interval.value > 0
            ? interval
            : CMTime(value: 1, timescale: 60)

        let candidate: CMTime
        if reported.isValid, reported.isNumeric {
            candidate = reported
        } else if last.isValid {
            candidate = CMTimeAdd(last, step)
        } else {
            // The host clock is what ScreenCaptureKit timestamps from, so this stays in the stream's timeline.
            candidate = CMClockGetTime(CMClockGetHostTimeClock())
        }

        guard candidate.isValid, candidate.isNumeric else { return nil }
        guard last.isValid, candidate <= last else { return candidate }
        return CMTimeAdd(last, step)
    }
}
