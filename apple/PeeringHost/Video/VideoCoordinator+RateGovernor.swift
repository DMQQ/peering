import Foundation
import RemoteCore
import os

private let rateLog = Logger(subsystem: "pl.dmq.peering.host", category: "encoder")

extension VideoCoordinator {
    private static let rateInterval: DispatchTimeInterval = .milliseconds(500)
    /// Where a new QUIC client starts, before the link is measured: 12 Mbit/s flooded a phone network for the first seconds of every relayed session. A fast link's capacity estimate lifts it within a second.
    private static let startingKbps = 3_000

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
                defer { rateGovernor = nil; governedLink = nil; linkCapKbps = nil }
                return linkCapKbps != nil
            }
            if wasGoverning { applyStreamShape() }
            return
        }
        let reading = QuicRateGovernor.Reading(
            ceilingKbps: askedBitrateKbps,
            backlogBytes: link.datagramBacklogBytes,
            deliveryRateBytesPerSecond: sample.deliveryRateBytesPerSecond,
            bandwidthBytesPerSecond: sample.bandwidthBytesPerSecond,
            roundTrip: sample.roundTrip,
            minimumRoundTrip: sample.minimumRoundTrip
        )
        let changed = lock.withLock { () -> Int? in
            // Per link: a governor left from the previous session skipped the new one's warm-up, and the relay's first keyframe sent it to the floor.
            let linkID = ObjectIdentifier(link)
            let first = rateGovernor == nil || governedLink != linkID
            var governor = (first ? nil : rateGovernor) ?? QuicRateGovernor(startingKbps: Self.startingKbps)
            defer { rateGovernor = governor; governedLink = linkID }
            let decided = governor.decide(reading)
            guard decided != nil || first else { return nil }
            linkCapKbps = governor.targetKbps
            return governor.targetKbps
        }
        guard let changed else { return }
        rateLog.notice("link carries the picture at \(changed, privacy: .public) kbps · backlog \(reading.backlogBytes, privacy: .public) B · delivered \(sample.deliveryRateBytesPerSecond * 8 / 1000, privacy: .public) kbps · rtt \(Self.milliseconds(sample.roundTrip), privacy: .public) ms (min \(Self.milliseconds(sample.minimumRoundTrip), privacy: .public))")
        applyStreamShape()
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
