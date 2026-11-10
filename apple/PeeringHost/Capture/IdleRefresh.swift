import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import RemoteCore

/// Re-sends the last picture once the screen has been still for a moment: a few times, each of which lets the encoder spend bits on the detail it skipped in motion. Without it a still screen keeps whatever the last motion left until the keyframe interval comes round.
/// The refresh frames are the real last buffer, not synthetic ones (see ``CapturePipeline/idleFramesEnabled``).
final class IdleRefresh: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.idle-refresh", qos: .userInitiated)
    /// Guards every property below, and is held across the refresh on purpose: a real frame's ``note(_:)`` waits for a refresh in flight, so a stale picture can never be encoded after a newer one. The real frame encodes inline on the capture thread too, so this adds no new wait for the encoder.
    private let lock = NSLock()
    /// Bumped by every real frame and by ``cancel()``; a scheduled repeat that finds a different number is stale and does nothing.
    private var generation = 0
    private var last: (frame: CapturedFrame, notedAt: DispatchTime)?
    private var repeatsDone = 0
    /// The picture kept once the repeats are over, as a private copy: the capture pool's buffer is given back then, and a keyframe asked for on a still screen had nothing left to encode, so it waited for the stream to redraw, two seconds after a desktop switch.
    private var stillCopy: (frame: CapturedFrame, notedAt: DispatchTime)?

    /// Called on `queue` with the last frame and a presentation time later than that frame's.
    private let refresh: @Sendable (CapturedFrame, CMTime) -> Void

    init(refresh: @escaping @Sendable (CapturedFrame, CMTime) -> Void) {
        self.refresh = refresh
    }

    /// Call before a real frame is encoded: it replaces the held picture and restarts the wait.
    func note(_ frame: CapturedFrame) {
        lock.withLock {
            generation &+= 1
            last = (frame, DispatchTime.now())
            stillCopy = nil
            repeatsDone = 0
            schedule(repeat: 0)
        }
    }

    /// Encodes the held picture at once, outside the schedule. False when nothing is held.
    func repeatNow() -> Bool {
        lock.withLock {
            guard let held = last ?? stillCopy else { return false }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - held.notedAt.uptimeNanoseconds) / 1_000_000_000
            refresh(held.frame, CMTimeAdd(held.frame.presentationTime, CMTime(seconds: elapsed, preferredTimescale: 1_000_000)))
            return true
        }
    }

    /// Releases the held picture, so a stopped stream does not keep one of the capture pool's buffers.
    func cancel() {
        lock.withLock {
            generation &+= 1
            last = nil
            stillCopy = nil
        }
    }

    /// False when `index` is past the last repeat. Call with `lock` held.
    @discardableResult
    private func schedule(repeat index: Int) -> Bool {
        guard let delay = StillPictureRefresh.delayMilliseconds(beforeRepeat: index) else { return false }
        let scheduledFor = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in self?.fire(generation: scheduledFor) }
        return true
    }

    private func fire(generation scheduledFor: Int) {
        lock.withLock {
            guard scheduledFor == generation, let held = last else { return }
            repeatsDone += 1
            // The pool buffer is needed only until the last repeat; holding it longer starves the capture stream while the screen is still.
            if !schedule(repeat: repeatsDone) {
                stillCopy = Self.copy(of: held)
                last = nil
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - held.notedAt.uptimeNanoseconds) / 1_000_000_000
            refresh(held.frame, CMTimeAdd(held.frame.presentationTime, CMTime(seconds: elapsed, preferredTimescale: 1_000_000)))
        }
    }

    /// A deep copy, so the capture pool's buffer can go back. Nil when a buffer cannot be made, which leaves the old behaviour.
    private static func copy(of held: (frame: CapturedFrame, notedAt: DispatchTime)) -> (frame: CapturedFrame, notedAt: DispatchTime)? {
        let source = held.frame.pixelBuffer
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes,
            &created
        ) == kCVReturnSuccess, let copy = created else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = max(CVPixelBufferGetPlaneCount(source), 1)
        for plane in 0..<planes {
            let isPlanar = CVPixelBufferGetPlaneCount(source) > 0
            guard let from = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy)
            else { return nil }
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let fromStride = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toStride = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
            for row in 0..<rows {
                memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
            }
        }
        let frame = held.frame
        return (CapturedFrame(pixelBuffer: copy, presentationTime: frame.presentationTime, duration: frame.duration, geometry: frame.geometry), held.notedAt)
    }
}
