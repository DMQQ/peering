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
    /// Once the lane has failed or been cancelled, no later race may install a fresh probe task.
    private var stopped = false

    /// How many probe attempts go by between two asks at the relay for the client's address.
    ///
    /// Twelve, which is one re-ask per three seconds while the probing is quick and one per minute
    /// once it has slowed, because the attempt counter is what both cadences are counted in. The
    /// same number the client uses, though neither end knows the other's: it is a cadence, not an
    /// agreement, and the two being equal is a coincidence of the same reasoning rather than a
    /// contract that would break if one changed.
    private static let rediscoverEvery = 12

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
        socket.onFailure = { [weak self] error in
            videoLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
            self?.stopProbing()
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
    /// **Silent on failure, and that is now the one asymmetry left.** The client half reports what
    /// its attempt came to, so the phone can say whether the relay never named the Mac or named it
    /// and the packets went nowhere. This end says nothing either way, which is defensible because
    /// the phone is where somebody looks, but it does mean a session can only be diagnosed from
    /// one side of it, and a Mac whose probes are the ones being dropped will look from the phone
    /// exactly like a Mac that is not probing at all.
    private func beginDirectPath() {
        let task = Task { [weak self] in
            guard let self else { return }
            let relay = self.relay

            // Quick while there is any prospect of it working, then slow for the rest of the
            // session: the fast phase is what opens the path, and the slow one is what recovers a
            // mapping that expired, for one small datagram every few seconds.
            //
            // **The asking is inside the loop rather than before it**, which is the fix for a
            // session that could have punched through and did not. The relay only knows where the
            // client is once the client has sent it a datagram, so "the peer has not been heard
            // from" is the *ordinary* first answer rather than a verdict, and it used to be taken
            // as one, permanently, by a `guard ... else { return }` that ran once.
            var attempt = 0
            while !Task.isCancelled {
                if attempt % Self.rediscoverEvery == 0 {
                    if let address = try? await RelaySignallingConnection.discoverPeer(
                        at: ProtocolInfo.relaySignallingURL,
                        videoToken: relay.videoToken
                    ) {
                        try? socket.setDirectPeer(host: address.host, port: address.port)
                    }
                }

                let probe = seal(kind: .directProbe, payload: Data())
                if !probe.isEmpty { socket.sendDirect(probe) { _ in } }
                attempt += 1
                let interval: Duration = attempt <= 12 ? .milliseconds(250) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            guard !stopped else {
                task.cancel()
                return nil
            }
            let previous = probeTask
            probeTask = task
            return previous
        }
        previous?.cancel()
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
        let frame = lock.withLock { () -> Frame? in
            // Mutated in place rather than through a copy: the replay window *is* the state, and a
            // probe replayed from a capture would otherwise be accepted as a fresh one.
            var opener = probeOpener
            defer { probeOpener = opener }
            return try? opener.open(datagram)
        }
        guard let frame else { return }

        // A ping asks to be timed, and a reply is the only thing that can answer it. Sealed
        // through the lane's one sealer — the counter inside is the AEAD nonce, so a sealer of its
        // own here would reuse one — and sent back the way the question came, because a question
        // that arrived through the relay is a question about the relay's path.
        if frame.kind == .ping {
            let pong = seal(kind: .pong, payload: frame.payload)
            guard !pong.isEmpty else { return }
            if case .peer = source {
                socket.sendDirect(pong) { _ in }
            } else {
                socket.send(pong) { _ in }
            }
            return
        }

        guard case .peer(let host, let port) = source else { return }

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
        stopProbing()
        socket.cancel()
    }

    private func stopProbing() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            let task = probeTask
            probeTask = nil
            return task
        }
        task?.cancel()
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
