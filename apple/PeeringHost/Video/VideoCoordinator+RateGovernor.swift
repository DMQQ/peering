import Foundation
import RemoteCore
import os

private let rateLog = Logger(subsystem: "pl.dmq.peering.host", category: "encoder")

extension VideoCoordinator {
    private static let rateInterval: DispatchTimeInterval = .milliseconds(500)
    /// Where a new QUIC client starts: high enough to look sharp at once, low enough not to flood a link before it has been measured.
    private static let startingKbps = 12_000

    /// Over QUIC, sets the picture's bitrate twice a second from what the link is measured to carry. Without a QUIC client it holds nothing, and the client's own figure applies.
    func startRateGovernor() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pl.dmq.peering.host.rate"))
        timer.schedule(deadline: .now() + Self.rateInterval, repeating: Self.rateInterval)
        timer.setEventHandler { [weak self] in self?.governRate() }
        lock.withLock { rateTimer = timer }
        timer.resume()
    }

    private func governRate() {
        guard let link = streamer.quicLink, link.isEstablished, let sample = link.pathSample else {
            let wasGoverning = lock.withLock { () -> Bool in
                defer { rateGovernor = nil; linkCapKbps = nil }
                return linkCapKbps != nil
            }
            if wasGoverning { applyStreamShape() }
            return
        }
        let reading = QuicRateGovernor.Reading(
            ceilingKbps: askedBitrateKbps,
            backlogBytes: link.datagramBacklogBytes,
            deliveryRateBytesPerSecond: sample.deliveryRateBytesPerSecond,
            bandwidthBytesPerSecond: sample.bandwidthBytesPerSecond
        )
        let changed = lock.withLock { () -> Int? in
            var governor = rateGovernor ?? QuicRateGovernor(startingKbps: Self.startingKbps)
            defer { rateGovernor = governor }
            let first = rateGovernor == nil
            let decided = governor.decide(reading)
            guard decided != nil || first else { return nil }
            linkCapKbps = governor.targetKbps
            return governor.targetKbps
        }
        guard let changed else { return }
        rateLog.notice("link carries the picture at \(changed, privacy: .public) kbps · backlog \(reading.backlogBytes, privacy: .public) B · delivered \(sample.deliveryRateBytesPerSecond * 8 / 1000, privacy: .public) kbps · rtt \(sample.roundTrip.components.attoseconds / 1_000_000_000_000_000, privacy: .public) ms")
        applyStreamShape()
    }
}
