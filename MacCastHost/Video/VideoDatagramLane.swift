import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// The relay's datagram path, as the video pipeline sees it: a socket to send on, and the
/// sealing that makes what goes out unreadable to the relay in the middle.
///
/// It exists as its own type because ``VideoStreamer`` has to treat it as a destination
/// without knowing anything about sockets, counters or ciphertext — the streamer decides
/// *which* lane a frame goes on, and everything about *how* it goes on that lane lives here.
///
/// The relay allocates the address and the token; the secret is this Mac's, generated when the
/// client asked for the lane and sent to it inside the control channel's TLS session. The
/// relay forwards the datagrams and cannot read one of them.
final class VideoDatagramLane: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: VideoDatagramSocket
    private var sealer: VideoDatagramSealer

    /// Opens what the *client* seals, which in this direction means one thing: a probe.
    ///
    /// The Mac's own picture goes the other way, so before the direct path existed there was nothing
    /// for this end to open and no reason to hold an opener at all. It exists now because a probe
    /// has to be *proved* rather than merely received: the address a datagram arrives from is not
    /// evidence of who sent it, and the only thing that is, is opening it with the session key.
    private var probeOpener: VideoDatagramOpener

    /// Where the client is, once something has arrived from it directly. `nil` until then.
    ///
    /// Held here as well as in the socket so the log line that says the path opened can name the
    /// address once rather than on every probe.
    private var directPeer: (host: String, port: UInt16)?

    /// The relay's allocation, kept so the probing task can name the session it is asking about.
    private let relay: RelaySession

    /// The task that asks where the client is and then keeps knocking.
    private var probeTask: Task<Void, Never>?

    /// - Throws: when the relay's allocation cannot be used — a token that is not the size the
    ///   wire contract fixes it at, or a port that is not a port. The caller refuses the
    ///   request rather than reporting a lane that cannot carry anything.
    init(relay: RelaySession, secret: Data) throws {
        self.relay = relay
        socket = try VideoDatagramSocket(
            host: relay.videoHost,
            port: relay.videoPort,
            token: relay.videoToken,
            label: "pl.dmq.peering.host.video.datagrams"
        )
        let schedule = VideoKeySchedule(secret: secret)
        sealer = try schedule.sealer(token: relay.videoToken, direction: .hostToClient)
        probeOpener = schedule.opener(direction: .clientToHost)
    }

    /// Opens the socket and binds, so the relay knows where this Mac's datagrams come from
    /// before the first of them is sent. See ``VideoDatagramSocket/start()``.
    func start() {
        socket.onFailure = { error in
            videoLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
        }
        socket.onDatagram = { [weak self] datagram, source in
            self?.accept(datagram, from: source)
        }
        socket.start()
        beginDirectPath()
    }

    /// Asks the relay where the client is, and then keeps knocking on its door.
    ///
    /// **The Mac has to knock as well as the phone, and this is the part that is easy to leave out.**
    /// A NAT that *maps* a port is not a NAT that *admits* traffic: the common kinds admit a packet
    /// from a given address only once the machine behind them has sent to that address. So a session
    /// where only one end probes opens on the permissive NATs and fails silently on the rest — which
    /// is the worst kind of networking bug, because it works on the developer's network.
    ///
    /// Both ends knocking within the same moment is the whole of what makes this work, and neither
    /// tells the other it is doing it: each discovers the other's address from the relay and sends.
    ///
    /// Silent on failure, like the client's half. A Mac that cannot discover its peer, or whose
    /// probes never arrive, is a Mac whose sessions stay on the relay — which is what every session
    /// did before this existed.
    private func beginDirectPath() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            guard let self else { return }
            let relay = self.relay
            let address = try? await RelaySignallingConnection.discoverPeer(
                at: ProtocolInfo.relaySignallingURL,
                videoToken: relay.videoToken
            )
            // No introduction means the client has not been heard from, and asking again would be
            // asking the same question of the same silence.
            guard let address, !Task.isCancelled else { return }
            try? socket.setDirectPeer(host: address.host, port: address.port)

            // Quick while there is any prospect of it working, then slow for the rest of the
            // session: the fast phase is what opens the path, and the slow one is what recovers a
            // mapping that expired — for one small datagram every few seconds.
            var attempt = 0
            while !Task.isCancelled {
                let probe = seal(kind: .directProbe, payload: Data())
                if !probe.isEmpty { socket.sendDirect(probe) { _ in } }
                attempt += 1
                let interval: Duration = attempt <= 12 ? .milliseconds(250) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Takes a datagram that arrived straight from the client, and sends the picture back the same
    /// way from then on.
    ///
    /// **The open is the whole of the trust.** Anyone who can write a source address into a packet
    /// can make a datagram arrive looking like the client's, and the address it claims is about to
    /// become where the video is sent — so the claim is checked by opening it with the key only the
    /// two ends hold. A forgery fails to open and changes nothing; that costs the forger the
    /// picture, which it could not have read anyway.
    ///
    /// Nothing is negotiated and nothing is acknowledged. The client does not learn from this end
    /// that it worked: it learns by the picture starting to arrive directly, which is the same fact
    /// observed from the other side and needs no message to establish.
    private func accept(_ datagram: Data, from source: VideoDatagramSocket.Source) {
        guard case .peer(let host, let port) = source else { return }

        let opened = lock.withLock { () -> Bool in
            // Mutated in place rather than through a copy: the replay window *is* the state, and a
            // probe replayed from a capture would otherwise be accepted as a fresh one.
            var opener = probeOpener
            defer { probeOpener = opener }
            return (try? opener.open(datagram)) != nil
        }
        guard opened else { return }

        // Every probe, not just the first: a NAT mapping that moves mid-session is the ordinary case
        // this whole design is built around, and the address that just worked is the address to use.
        let moved = lock.withLock { () -> Bool in
            let changed = directPeer?.host != host || directPeer?.port != port
            directPeer = (host, port)
            return changed
        }
        guard moved else { return }

        do {
            try socket.setDirectPeer(host: host, port: port)
            videoLog.notice("the client is reachable directly at \(host, privacy: .public):\(port, privacy: .public)")
        } catch {
            videoLog.error("the client's direct address could not be used: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel() {
        probeTask?.cancel()
        probeTask = nil
        socket.cancel()
    }

    var sentDatagrams: Int { socket.sentDatagrams }

    /// The datagrams one payload becomes, sealed and ready to send.
    ///
    /// Called with the streamer's lock held, which is what keeps the chunk numbering of one
    /// frame from being handed to another.
    func seal(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock { sealer.seal(kind: kind, payload: payload) }
    }

    /// Sends a group of datagrams and reports when the last one is away. The completion is the
    /// streamer's flow control, exactly as it is for a write to a connection.
    func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        socket.send(datagrams, completion: completion)
    }
}
