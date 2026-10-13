import CoreMedia
import Foundation
import PeeringKit
import ScreenCaptureKit
import os

private let pacerLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Lowers the running stream's minimum frame interval while the client asks for fewer frames, so capture and encode do less work rather than only dropping frames after the fact.
/// Only the interval changes in the configuration passed to `updateConfiguration`: a different size or format is what makes a reconfigure stall or change geometry.
final class StreamPacer: @unchecked Sendable {
    private struct Attached {
        let stream: SCStream
        var configuration: SCStreamConfiguration
        let baseRate: Int
        var appliedRate: Int
    }

    // `attached`, `requested` and `serial` are guarded by `lock`.
    private let lock = NSLock()
    private var attached: Attached?
    private var requested: Int?
    private var serial: SerialAsyncQueue<Void>?

    /// A stream with no interval of its own has no rate to lower. A request made before the stream existed is applied now.
    func attach(stream: SCStream, configuration: SCStreamConfiguration) {
        let interval = configuration.minimumFrameInterval
        guard let rate = StreamPacing.rate(intervalValue: interval.value, intervalTimescale: interval.timescale) else { return }
        lock.withLock { attached = Attached(stream: stream, configuration: configuration, baseRate: rate, appliedRate: rate) }
        reconcile()
    }

    func detach() {
        lock.withLock { attached = nil }
    }

    /// Nil, or a rate at or above the one the stream started at, restores it.
    func limit(to framesPerSecond: Int?) {
        lock.withLock { requested = framesPerSecond }
        reconcile()
    }

    private func reconcile() {
        queue().enqueue(())
    }

    private func queue() -> SerialAsyncQueue<Void> {
        if let existing = lock.withLock({ serial }) { return existing }
        let created = SerialAsyncQueue<Void> { [weak self] in await self?.applyPending() }
        return lock.withLock { () -> SerialAsyncQueue<Void> in
            if let existing = serial { return existing }
            serial = created
            return created
        }
    }

    private func applyPending() async {
        let work = lock.withLock { () -> (stream: SCStream, update: SCStreamConfiguration, rate: Int)? in
            guard let current = attached else { return nil }
            let rate = StreamPacing.streamRate(requested: requested, base: current.baseRate)
            guard rate != current.appliedRate, let copy = current.configuration.copy() as? SCStreamConfiguration else { return nil }
            copy.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
            return (current.stream, copy, rate)
        }
        guard let work else { return }
        do {
            try await work.stream.updateConfiguration(work.update)
            lock.withLock {
                guard attached?.stream === work.stream else { return }
                attached?.configuration = work.update
                attached?.appliedRate = work.rate
            }
            pacerLog.notice("capture stream paced to \(work.rate, privacy: .public) fps")
        } catch {
            pacerLog.error("capture stream could not be paced: \(error.localizedDescription, privacy: .public)")
        }
    }
}
