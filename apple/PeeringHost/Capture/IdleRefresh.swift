import CoreMedia
import Dispatch
import Foundation
import RemoteCore

/// Re-sends the last picture once the screen has been still for a moment: a few times, each of which lets the encoder spend bits on the detail it skipped in motion. Without it a still screen keeps whatever the last motion left until the keyframe interval comes round.
/// The refresh frames are the real last buffer, not synthetic ones (see ``CapturePipeline/idleFramesEnabled``).
final class IdleRefresh: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.idle-refresh", qos: .userInitiated)
    /// Guards every property below. Held across the refresh so a real frame's ``note(_:source:)`` waits for it and presentation times stay increasing.
    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    private var last: (frame: CapturedFrame, notedAt: DispatchTime)?

    private var repeatsDone = 0

    /// Called on `queue` with the last frame, and a presentation time later than any already encoded.
    private let refresh: @Sendable (CapturedFrame, CMTime) -> Void

    init(refresh: @escaping @Sendable (CapturedFrame, CMTime) -> Void) {
        self.refresh = refresh
    }

    /// Call before a real frame is encoded: it replaces the held picture and restarts the wait.
    func note(_ frame: CapturedFrame) {
        lock.withLock {
            pending?.cancel()
            last = (frame, DispatchTime.now())
            repeatsDone = 0
            schedule(repeat: 0)
        }
    }

    /// Releases the held picture, so a stopped stream does not keep one of the capture pool's buffers.
    func cancel() {
        lock.withLock {
            pending?.cancel()
            pending = nil
            last = nil
        }
    }

    /// Call with `lock` held.
    private func schedule(repeat index: Int) {
        guard let delay = StillPictureRefresh.delayMilliseconds(beforeRepeat: index) else { return }
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func fire() {
        lock.withLock {
            guard let held = last, pending?.isCancelled == false else { return }
            repeatsDone += 1
            pending = nil
            schedule(repeat: repeatsDone)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - held.notedAt.uptimeNanoseconds) / 1_000_000_000
            let time = CMTimeAdd(held.frame.presentationTime, CMTime(seconds: elapsed, preferredTimescale: 1_000_000))
            // Called with the lock held on purpose: the encoder does not call back into this type.
            refresh(held.frame, time)
        }
    }
}
