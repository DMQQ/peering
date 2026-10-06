import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

private let overlayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A larger pointer drawn into the picture: ScreenCaptureKit offers only show/hide cursor switches with no size.
/// The stream leaves the system pointer visible (its movement keeps frames coming on a quiet desktop) and this opaque shape covers it at the same tip.
/// Luma plane only (frames are 420v). The values are 16 and 235, not 0 and 255: video range, and out-of-range luma is not clamped on the way through. Nothing allocates per frame.
/// The synthetic pipeline cannot use this: generated frames describe no screen. See CapturePipeline/ingest(_:).
final class CursorOverlay: @unchecked Sendable {
    enum Size: String, CaseIterable, Sendable {
        case small
        case medium
        case large

        var fractionOfHeight: CGFloat {
            switch self {
            case .small: return 0.032   // roughly twice the system's pointer
            case .medium: return 0.048  // roughly three times
            case .large: return 0.064   // roughly four times
            }
        }
    }

    private static let ink: UInt8 = 235
    private static let edge: UInt8 = 16

    /// Half is stroked outside the outline and half under the fill, so the visible edge is thinner. Scales with the pointer so the separator holds at any size.
    private static let edgeWidth: CGFloat = 0.09

    /// A polygon, not a bitmap of the system cursor: its one-pixel steps become a staircase when scaled up.
    private static let outline: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),  // the tip, which is where the pointer is
        CGPoint(x: 0.000, y: 0.707),  // down the left edge, which is vertical
        CGPoint(x: 0.201, y: 0.512),  // up into the notch between the head and the tail
        CGPoint(x: 0.390, y: 0.963),  // down the tail's left side to its foot
        CGPoint(x: 0.549, y: 0.896),  // across the foot
        CGPoint(x: 0.360, y: 0.445),  // back up the tail's right side
        CGPoint(x: 0.622, y: 0.445),  // out to the head's bottom right corner
    ]

    private struct Pass {
        let range: Range<Int>
        let value: UInt8
    }

    private let lock = NSLock()

    /// Each closed by repeating its first point. Edge quads first and the outline last: the fill covers the inner half of its own edge.
    private let vertices: [CGPoint]
    private let passes: [Pass]

    private var intersections = [CGFloat](repeating: 0, count: 16)

    private var reportedRefusal = false

    /// Nil whenever no frame carries a pointer; rounding to the pixel keeps an idle sample from earning a frame unless the tip moved.
    private var drawnTip: CGPoint?

    /// An idle sample need not say, and the screen has not changed since a frame that did. See redraw(_:).
    private var lastTransform: InputTransform?

    private var scratch: Scratch?

    private var enabled: Bool
    private var chosenSize: Size

    init(isEnabled: Bool = true, size: Size = .medium) {
        self.enabled = isEnabled
        self.chosenSize = size
        (self.vertices, self.passes) = Self.shape()
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var size: Size {
        get { lock.withLock { chosenSize } }
        set { lock.withLock { chosenSize = newValue } }
    }

    // MARK: - Drawing

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

    // MARK: - Idle frames

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

    private struct Region {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The buffers idle frames are built in. The pool only hands over a buffer nothing else holds, so acquiring one answers whether the encoder is finished with it (see acquire(_:)).
    /// More than one: VideoToolbox keeps a frame until the next is encoded and idle frames are unevenly spaced, so a pool of one could be left with nothing to draw in. Each buffer keeps the pixels under its pointer and its own record.
    private struct Scratch {
        /// The picture with no pointer in it, as of the last delivered frame; owned here and never handed to the encoder, so always safe to write.
        let picture: CVPixelBuffer
        /// Bumped on every rewrite of picture; a pool buffer holding another number holds a stale screen.
        var generation: UInt64
        var holdsPicture: Bool
        var pictureArrived: Bool

        let pool: CVPixelBufferPool
        let width: Int
        let height: Int
        var geometry: FrameGeometry
        var lastSentTime: CMTime
        var lastInterval: CMTime
        /// Room for the pixels under the pointer, sized for the largest preference rather than the one in force.
        let patchWidth: Int
        let patchHeight: Int
        var buffers: [Buffer]

        /// A ceiling on buffers, in case the pool hands back more than its threshold.
        static let bufferLimit = 4

        struct Buffer {
            /// How a buffer is recognised across acquisitions: the pool hands back a surface, not an object.
            let planeBase: UnsafeMutableRawPointer
            var stride: Int
            var patch: [UInt8]
            /// nil when no pointer is drawn in this buffer; region and patch go together, or a rectangle of picture is put back over a pointer never there.
            var patchRegion: Region?
            /// A different number means the pixels outside the pointer are an older screen.
            var generation: UInt64
        }
    }

    /// The pool is capped at Scratch/bufferLimit and only hands over a buffer nothing else holds, so a failure means the encoder has them all and this sample is dropped. Idle frames go out no faster than the encoder retires them.
    private func acquire(_ scratch: Scratch) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            scratch.pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Scratch.bufferLimit] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Made again if the stream's surface changes size. Must be called with the lock held, on the capture queue.
    private func makeScratch(width: Int, height: Int, geometry: FrameGeometry) -> Scratch? {
        // Measured from the shape itself, so changing the outline cannot leave the patch too small to take a pointer back out.
        let box = bounds(tip: .zero, scale: CGFloat(height) * Size.large.fractionOfHeight)
        let patchWidth = Int(box.width.rounded(.up)) + 2
        let patchHeight = Int(box.height.rounded(.up)) + 2
        guard patchWidth > 0, patchHeight > 0 else { return nil }

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        // Made plainly, not from the pool: it is never handed out, and the pool would subject it to an allocation threshold.
        var picture: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            bufferAttributes as CFDictionary,
            &picture
        ) == kCVReturnSuccess, let picture else { return nil }

        let poolAttributes: [CFString: Any] = [
            // Pool buffers age out after a second by default; an aged-out buffer comes back with nothing of this object's in it.
            kCVPixelBufferPoolMaximumBufferAgeKey: 0,
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else { return nil }

        return Scratch(
            picture: picture,
            generation: 0,
            holdsPicture: false,
            pictureArrived: true,
            pool: pool,
            width: width,
            height: height,
            geometry: geometry,
            lastSentTime: .invalid,
            lastInterval: .invalid,
            patchWidth: patchWidth,
            patchHeight: patchHeight,
            buffers: []
        )
    }

    /// Keeps the screen without a pointer, copied before the pointer is drawn into the frame. A failure leaves the picture and generation unchanged, so an idle frame draws over a screen one frame old rather than not at all.
    private func refresh(from frame: CVPixelBuffer, geometry: FrameGeometry) {
        let width = CVPixelBufferGetWidthOfPlane(frame, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame, 0)

        lock.withLock {
            var scratch: Scratch
            if let existing = self.scratch, existing.width == width, existing.height == height {
                scratch = existing
            } else {
                // Made and filled in one call: a kept but empty picture is refused until the stream delivers another frame, which a still screen never does.
                guard let fresh = makeScratch(width: width, height: height, geometry: geometry) else {
                    self.scratch = nil
                    return
                }
                scratch = fresh
            }

            // Held across the copy, the one slow moment under this lock (a few hundred microseconds for a display-sized frame).
            guard CVPixelBufferLockBaseAddress(scratch.picture, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(scratch.picture, []) }

            guard Self.copyPicture(from: frame, into: scratch.picture) else { return }
            scratch.generation += 1
            scratch.holdsPicture = true
            scratch.pictureArrived = true
            scratch.geometry = geometry
            self.scratch = scratch
        }
    }

    /// Whole because a delivered frame says the display changed without saying where. Reports success so a half-copied picture does not advance a generation.
    @discardableResult
    private static func copyPicture(from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        copyPlane(0, from: source, into: destination) && copyPlane(1, from: source, into: destination)
    }

    private static func copyPlane(_ index: Int, from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, index),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, index)
        else {
            return false
        }

        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, index)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, index)
        let bytes = min(sourceStride, destinationStride)
        let rows = min(
            CVPixelBufferGetHeightOfPlane(source, index),
            CVPixelBufferGetHeightOfPlane(destination, index)
        )
        guard bytes > 0, rows > 0 else { return false }

        let sourceRows = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destinationRows = destinationBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            memcpy(destinationRows + row * destinationStride, sourceRows + row * sourceStride, bytes)
        }
        return true
    }

    private func save(
        _ region: Region,
        from plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        into patch: inout [UInt8]
    ) {
        patch.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    base + row * region.width,
                    plane + (region.y + row) * stride + region.x,
                    region.width
                )
            }
        }
    }

    private func restore(
        _ region: Region,
        from patch: [UInt8],
        into plane: UnsafeMutablePointer<UInt8>,
        stride: Int
    ) {
        patch.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    plane + (region.y + row) * stride + region.x,
                    base + row * region.width,
                    region.width
                )
            }
        }
    }

    /// The union of every polygon's bounds: a rectangle a pixel too small leaves a trail of arrows.
    private func bounds(tip: CGPoint, scale: CGFloat) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in vertices {
            let x = tip.x + point.x * scale
            let y = tip.y + point.y * scale
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rounded outward: the rasteriser rounds crossings per row, and a tight box leaves the pointer behind on its outermost row and column.
    private static func region(_ box: CGRect, width: Int, height: Int) -> Region? {
        guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite else {
            return nil
        }
        let first = max(0, Int(box.minX.rounded(.down)))
        let last = min(width - 1, Int(box.maxX.rounded(.up)))
        let top = max(0, Int(box.minY.rounded(.down)))
        let bottom = min(height - 1, Int(box.maxY.rounded(.up)))
        guard last >= first, bottom >= top else { return nil }
        return Region(x: first, y: top, width: last - first + 1, height: bottom - top + 1)
    }

    // MARK: - Reporting

    /// Once only: the cause is a property of the stream or pixel format, so it holds for every frame, and a missing pointer looks like one never asked for. Not called for the pointer being elsewhere.
    private func report(_ reason: String) {
        let isFirst = lock.withLock { () -> Bool in
            guard !reportedRefusal else { return false }
            reportedRefusal = true
            return true
        }
        guard isFirst else { return }
        overlayLog.notice("no pointer drawn into a frame: \(reason, privacy: .public)")
    }

    /// A scanline fill: the work is in the outline, not its area.
    private func rasterize(
        _ pass: Pass,
        tip: CGPoint,
        scale: CGFloat,
        plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int
    ) {
        // One crossing per edge is the worst case, which keeps the fixed array honest.
        guard pass.range.count <= intersections.count else { return }

        let last = pass.range.upperBound - 1
        guard last > pass.range.lowerBound else { return }

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        var index = pass.range.lowerBound
        while index < last {
            let a = vertices[index]
            let b = vertices[index + 1]
            let ax = tip.x + a.x * scale
            let bx = tip.x + b.x * scale
            let ay = tip.y + a.y * scale
            let by = tip.y + b.y * scale

            minX = min(minX, min(ax, bx))
            maxX = max(maxX, max(ax, bx))
            minY = min(minY, min(ay, by))
            maxY = max(maxY, max(ay, by))

            index += 1
        }

        let firstRow = max(0, Int(minY.rounded(.down)))
        let lastRow = min(height - 1, Int(maxY.rounded(.up)))
        guard firstRow <= lastRow, maxX >= 0, minX <= CGFloat(width - 1) else { return }

        for row in firstRow...lastRow {
            let sample = CGFloat(row) + 0.5
            var crossings = 0

            var index = pass.range.lowerBound
            while index < last {
                let ay = tip.y + vertices[index].y * scale
                let by = tip.y + vertices[index + 1].y * scale

                // Half-open in y, so a row through a vertex is counted by one of the two edges meeting there, not both.
                if (ay <= sample) != (by <= sample) {
                    let ax = tip.x + vertices[index].x * scale
                    let bx = tip.x + vertices[index + 1].x * scale
                    let t = (sample - ay) / (by - ay)
                    intersections[crossings] = ax + t * (bx - ax)
                    crossings += 1
                }

                index += 1
            }

            guard crossings >= 2 else { continue }

            // By hand: at most seven, and a sort called eight times a frame must not allocate.
            for i in 1..<crossings {
                let value = intersections[i]
                var j = i
                while j > 0, intersections[j - 1] > value {
                    intersections[j] = intersections[j - 1]
                    j -= 1
                }
                intersections[j] = value
            }

            let line = plane + row * stride
            var pair = 0
            while pair + 1 < crossings {
                let from = max(0, Int((intersections[pair] - 0.5).rounded(.up)))
                let to = min(width - 1, Int((intersections[pair + 1] - 0.5).rounded(.down)))
                if from <= to {
                    memset(line + from, Int32(pass.value), to - from + 1)
                }
                pair += 2
            }
        }
    }

    // MARK: - Shape

    private static func shape() -> (vertices: [CGPoint], passes: [Pass]) {
        var vertices: [CGPoint] = []
        var passes: [Pass] = []

        for index in outline.indices {
            let quad = stroke(from: outline[index], to: outline[(index + 1) % outline.count])
            guard let first = quad.first else { continue }
            let start = vertices.count
            vertices.append(contentsOf: quad)
            vertices.append(first)
            passes.append(Pass(range: start..<vertices.count, value: edge))
        }

        let start = vertices.count
        vertices.append(contentsOf: outline)
        vertices.append(outline[0])
        passes.append(Pass(range: start..<vertices.count, value: ink))

        return (vertices, passes)
    }

    private static func stroke(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [] }

        let half = edgeWidth / 2
        let nx = -dy / length * half
        let ny = dx / length * half

        return [
            CGPoint(x: a.x + nx, y: a.y + ny),
            CGPoint(x: b.x + nx, y: b.y + ny),
            CGPoint(x: b.x - nx, y: b.y - ny),
            CGPoint(x: a.x - nx, y: a.y - ny),
        ]
    }
}
