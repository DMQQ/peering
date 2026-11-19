import Foundation
import RemoteCore
import os

private let quicLog = Logger(subsystem: "pl.dmq.peering.host", category: "quic")

extension HostServer {
    /// How long a relay allocation waits for the phone's first QUIC packet before it is given up.
    private static let quicArrivalWindow: TimeInterval = 30

    /// Waits for the phone over QUIC behind the relay's UDP port, with this Mac's relay token in front of every packet. The whole session (control, picture, sound) then runs on that one connection.
    func listenOverQuic(_ relaySession: RelaySession) {
        queue.async { [weak self] in
            guard let self, isListening else { return }
            do {
                let configuration = try QuicConfiguration(identity: identity)
                guard let relayAddress = QuicAddress.resolve(host: relaySession.videoHost, port: relaySession.videoPort) else {
                    emit(.failed("The relay's address could not be resolved"))
                    return
                }
                let link = try QuicFrameLink.listen(
                    port: 0,
                    relay: QuicEndpoint.RelayRoute(address: relayAddress, token: relaySession.videoToken),
                    configuration: configuration,
                    label: "pl.dmq.peering.host.quic"
                )
                awaitHandshake(of: link, relayed: true)
                queue.asyncAfter(deadline: .now() + Self.quicArrivalWindow) { [link] in
                    guard !link.isEstablished else { return }
                    link.onEstablished = nil
                    link.close(reason: "no phone arrived")
                }
            } catch {
                Analytics.failed(error, in: .network)
                emit(.failed("Could not wait for the phone over QUIC: \(error.localizedDescription)"))
            }
        }
    }

    /// Held by its own callback until the handshake finishes or the link closes; nothing else owns a link that has no session yet.
    func awaitHandshake(of link: QuicFrameLink, relayed: Bool) {
        link.onEstablished = { [weak self, link] in
            link.onEstablished = nil
            self?.queue.async { self?.acceptQuic(link, relayed: relayed) }
        }
    }

    private func acceptQuic(_ link: QuicFrameLink, relayed: Bool) {
        let address = relayed ? "relay-quic-\(UUID().uuidString.prefix(8))" : (link.peerAddress?.hostText ?? "lan-quic")
        guard admitBeforeAuthentication(address: address) else {
            link.close(reason: "refused")
            return
        }
        quicLog.notice("a phone arrived over QUIC \(relayed ? "through the relay" : "on the LAN", privacy: .public)")
        let peer = PeerConnection(quic: link, queue: queue)
        start(peer, address: address, tunnel: nil, relayed: relayed)
    }
}
