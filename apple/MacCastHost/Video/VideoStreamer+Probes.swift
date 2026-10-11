import Foundation
import RemoteCore
import os

extension VideoStreamer {
    func ensureProbeTimer() {
        lock.lock()
        guard probeTimer == nil, peer != nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: Self.probeQueue)
        timer.schedule(
            deadline: .now() + Self.probeInterval,
            repeating: Self.probeInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in self?.askForAProbeKeyframe() }
// Resumed before it is stored, so every reference anyone else can reach is a live one: a suspended
// dispatch source that is cancelled and released is a crash.
        timer.resume()
        probeTimer = timer
        lock.unlock()
    }

    func stopProbeTimer() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let timer = probeTimer
            probeTimer = nil
            return timer
        }
        timer?.cancel()
    }

/// Asks the encoder for a keyframe if nothing has been offered to the preferred transport for a whole
/// interval.
    func askForAProbeKeyframe() {
        let now = Self.monotonicNow()
        let ask = lock.withLock { () -> Bool in
            guard transport == .control, peer != nil else { return false }
            return now - max(lastProbeAt, lastKeyframeAt) >= Self.probeInterval
        }
        if ask { requestKeyframe() }
    }

    static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
