import Foundation
import RemoteCore
import os

private let quicLog = Logger(subsystem: "pl.dmq.peering.host", category: "quic")

extension HostServer {
    /// Waits for the phone behind the relay as well as on the LAN: the allocation becomes one more socket of the QUIC listener. A phone connecting through it opens a new session; one whose session began on the LAN arrives on the connection it already has.
    func listenOverQuic(_ relaySession: RelaySession) {
        queue.async { [weak self] in
            guard let self, isListening, let listener = quicListener else { return }
            guard let relayAddress = QuicAddress.resolve(host: relaySession.videoHost, port: relaySession.videoPort) else {
                emit(.failed("The relay's address could not be resolved"))
                return
            }
            do {
                try listener.attachRelay(QuicEndpoint.RelayRoute(address: relayAddress, token: relaySession.videoToken))
            } catch {
                Analytics.failed(error, in: .network)
                emit(.failed("Could not wait for the phone over QUIC: \(error.localizedDescription)"))
            }
        }
    }

    /// Held by its own callback until the handshake finishes or the link closes; nothing else owns a link that has no session yet. `relay` is nil for a phone on the LAN.
    func awaitHandshake(of link: QuicFrameLink, relay: QuicEndpoint.RelayRoute?) {
        link.onEstablished = { [weak self, link] in
            link.onEstablished = nil
            self?.queue.async { self?.acceptQuic(link, relay: relay) }
        }
    }

    /// A session that began on the LAN came through a relay port: from now on the Mac knocks and keeps the route, as for one that began there.
    func adoptRelay(_ route: QuicEndpoint.RelayRoute, for link: QuicFrameLink) {
        queue.async { [weak self] in
            guard let self, let peer = quicPeers[ObjectIdentifier(link)]?.peer else { return }
            peer.run(directPath(for: link, route: route))
        }
    }

    private func acceptQuic(_ link: QuicFrameLink, relay: QuicEndpoint.RelayRoute?) {
        let relayed = relay != nil
        let address = relayed ? "relay-quic-\(UUID().uuidString.prefix(8))" : (link.peerAddress?.hostText ?? "lan-quic")
        guard admitBeforeAuthentication(address: address) else {
            link.close(reason: "refused")
            return
        }
        quicLog.notice("a phone arrived over QUIC \(relayed ? "through the relay" : "on the LAN", privacy: .public)")
        let peer = PeerConnection(quic: link, queue: queue)
        quicPeers = quicPeers.filter { $0.value.peer != nil }
        quicPeers[ObjectIdentifier(link)] = WeakPeer(peer: peer)
        announceLANAddresses(on: link)
        if let relay { peer.directPath = directPath(for: link, route: relay) }
        start(peer, address: address, tunnel: nil, relayed: relayed)
    }

    /// Where a phone on this Mac's network reaches it: the way back to the LAN for a session on the relay, whose view of this Mac is the router's public address, which a phone behind the same router usually cannot loop back to.
    private func announceLANAddresses(on link: QuicFrameLink) {
        guard let port = quicListener?.localPort else { return }
        let addresses = privateIPv4Addresses().map { "\($0):\(port)" }
        guard !addresses.isEmpty, let payload = try? MessageCodec.encode(DirectCandidates(addresses: addresses)) else { return }
        link.send(Frame(kind: .directCandidates, payload: payload))
    }

    /// The Mac knocks so its NAT lets the phone's probes in, and follows the phone onto whichever path validates.
    private func directPath(for link: QuicFrameLink, route: QuicEndpoint.RelayRoute) -> QuicDirectPath {
        QuicDirectPath(link: link, relay: route.address, role: .listener, videoToken: route.token) { change in
            switch change {
            case .onPath(let path):
                quicLog.notice("the session moved to the \(String(describing: path), privacy: .public) path")
            case .report(let outcome):
                quicLog.notice("direct path: \(outcome.summary, privacy: .public)")
            case .verdictDue:
                quicLog.notice("direct path: no answer within \(Int(ClientSession.DirectPath.verdictAfter), privacy: .public) seconds")
            case .renewRelay:
                break
            }
        }
    }
}

/// A QUIC session's connection, held weakly so the table of them never keeps a finished one alive.
struct WeakPeer {
    weak var peer: PeerConnection?
}
