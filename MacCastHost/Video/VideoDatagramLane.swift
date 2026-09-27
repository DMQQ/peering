import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// The relay's datagram path, as the video pipeline sees it: a socket to send on, and the sealing
/// that makes what goes out unreadable to the relay in the middle.
///
/// Its own type so that ``VideoStreamer`` can treat it as a destination without knowing anything
/// about sockets, counters or ciphertext: the streamer decides which lane a frame goes on, and
/// everything about how it goes on that lane lives here.
///
/// The relay allocates the address and the token; the secret is this Mac's, generated when the
/// client asked for the lane and sent to it inside the control channel's TLS session. The relay
/// forwards the datagrams and cannot read one of them.
final class VideoDatagramLane: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: VideoDatagramSocket
    private var sealer: VideoDatagramSealer

/// Opens what the client seals, which in this direction means one thing: a probe.
///
/// A probe has to be proved rather than merely received: the address a datagram arrives from is
/// not evidence of who sent it, and the only thing that is, is opening it with the session key.
    private var probeOpener: VideoDatagramOpener

/// Where the client is, once something has arrived from it directly. `nil` until then.
///
/// Held here as well as in the socket so the log line that says the path opened can name the
/// address once rather than on every probe.
    private var directPeer: (host: String, port: UInt16)?

/// What the attempt has come to, so that it can be said once per change rather than per probe.
///
/// The client's own type rather than a second enum spelled the same way: it is one feature with
/// two ends, so the two logs can be read against each other without a translation. The words are
/// this end's own; see ``sentence(for:)``.
    private var probeStatus: ClientSession.DirectPath = .notTried

    var isDirectOpen: Bool {
        lock.withLock {
            if case .open = probeStatus { return true }
            return false
        }
    }

/// The last discovery that threw, kept so that one is said once rather than on every re-ask.
///
/// Its own state because it is its own fault: "the relay has not said where the client is" is an
/// answer about the client, and this is the relay not answering at all.
    private var discoveryFailure: String?

    /// The relay's allocation, kept so the probing task can name the session it is asking about.
    private let relay: RelaySession

    /// The task that asks where the client is and then keeps knocking.
    private var probeTask: Task<Void, Never>?
    /// Once the lane has failed or been cancelled, no later race may install a fresh probe task.
    private var stopped = false

/// How many probe attempts go by between two asks at the relay for the client's address.
///
/// Twelve, which is one re-ask per three seconds while the probing is quick and one per minute
/// once it has slowed, because the attempt counter is what both cadences are counted in.
    private static let rediscoverEvery = 12

/// - Throws: when the relay's allocation cannot be used: a token that is not the size the wire
///   contract fixes it at, or a port that is not a port. The caller refuses the request rather
///   than reporting a lane that cannot carry anything.
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

/// Opens the socket and binds, so the relay knows where this Mac's datagrams come from before the
/// first of them is sent. See ``VideoDatagramSocket/start()``.
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
/// The Mac has to knock as well as the phone. A NAT that maps a port is not a NAT that admits
/// traffic: the common kinds admit a packet from a given address only once the machine behind them
/// has sent to that address, so a session where only one end probes opens on the permissive NATs
/// and fails silently on the rest. Both ends knock within the same moment, and neither tells the
/// other it is doing it: each discovers the other's address from the relay and sends.
///
/// What it comes to is said here too, in the client's own five outcomes. A firewall, a NAT and a
/// relay that will not answer are all facts this end can see and the phone cannot, and when a
/// session will not open at all it is the phone's log that cannot be read. ``note(_:)`` says each
/// of them once.
    private func beginDirectPath() {
        let task = Task { [weak self] in
            guard let self else { return }
            let relay = self.relay

// Quick while there is any prospect of it working, then slow for the rest of the session: the
// fast phase is what opens the path, and the slow one recovers a mapping that expired.
//
// The asking is inside the loop rather than before it. The relay only knows where the client is
// once the client has sent it a datagram, so "the peer has not been heard from" is the ordinary
// first answer rather than a verdict, and a guard outside the loop took it as one permanently.
            var attempt = 0
            while !Task.isCancelled {
                if attempt % Self.rediscoverEvery == 0 {
                    do {
                        if let address = try await RelaySignallingConnection.discoverPeer(
                            at: ProtocolInfo.relaySignallingURL,
                            videoToken: relay.videoToken
                        ) {
                            self.clearDiscoveryFailure()
                            let peer = "\(address.host):\(address.port)"
                            do {
                                try socket.setDirectPeer(host: address.host, port: address.port)
                                self.note(.probing(peer: peer))
                            } catch {
// The address came back and this Mac cannot address it, which is the client's own
// `.addressUnusable` seen from the far side, so it is an error and not only a status.
                                if self.note(.addressUnusable(peer: peer)) {
                                    videoLog.error("the client is at \(peer, privacy: .public), which this Mac cannot address: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        } else {
// Not a failure, and the ordinary first answer: the relay only knows where the client is once
// the client has sent it a datagram.
                            self.note(.noAddress)
                        }
                    } catch {
                        self.noteDiscoveryFailure(error)
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

/// Whether this outcome is news, recording it if it is.
///
/// The loop above asks every three seconds and then every minute for the whole session, so a state
/// announced on every pass is a state nobody reading the log can tell from a repeat. A path that
/// is open is not closed by a later look-up: a re-ask returns a candidate address, and a candidate
/// is not a statement about the path already carrying the picture.
    private func record(_ outcome: ClientSession.DirectPath) -> Bool {
        lock.withLock {
            if case .open = probeStatus, case .probing = outcome { return false }
            guard probeStatus != outcome else { return false }
            probeStatus = outcome
            return true
        }
    }

/// Records what the attempt has come to, and says it when that is news.
///
/// The outcomes are the client's own type, so a session that never punched and a session that
/// punched and then lost it are the same story told from both ends.
    @discardableResult
    private func note(_ outcome: ClientSession.DirectPath) -> Bool {
        guard record(outcome) else { return false }
        videoLog.notice("direct path: \(Self.sentence(for: outcome), privacy: .public)")
        return true
    }

/// The outcome in this end's words.
///
/// The cases are shared with the client so that the two ends agree about what happened; the
/// sentences cannot be, because the client's summary says "this phone" and "the Mac", which is
/// backwards in a Mac's log.
    private static func sentence(for outcome: ClientSession.DirectPath) -> String {
        switch outcome {
        case .notTried: return "Not tried"
        case .noAddress: return "The relay has not said where the client is"
        case .probing(let peer): return "Knocking on \(peer), nothing back yet"
        case .addressUnusable(let peer): return "The relay named \(peer), which this Mac cannot use"
        case .open(let peer): return "Straight to \(peer)"
        }
    }

    /// Forgets the last discovery failure, so that the next one is said afresh.
    private func clearDiscoveryFailure() {
        lock.withLock { discoveryFailure = nil }
    }

/// Says a discovery that threw, once rather than on every re-ask.
///
/// Kept apart from the outcomes above because it is a different fault with a different fix: the
/// relay not being reachable at all, rather than the relay having nothing yet to say.
    private func noteDiscoveryFailure(_ error: Error) {
        let line = error.localizedDescription
        let changed = lock.withLock { () -> Bool in
            guard discoveryFailure != line else { return false }
            discoveryFailure = line
            return true
        }
        guard changed else { return }
        videoLog.error("the relay could not be asked where the client is: \(line, privacy: .public)")
    }

/// Takes a datagram that arrived straight from the client, and sends the picture back the same way
/// from then on.
///
/// The open is the whole of the trust. Anyone who can write a source address into a packet can
/// make a datagram arrive looking like the client's, and the address it claims is about to become
/// where the video is sent, so the claim is checked by opening it with the key only the two ends
/// hold. A forgery fails to open and changes nothing.
///
/// Nothing is negotiated and nothing is acknowledged: the client learns it worked by the picture
/// starting to arrive directly.
    private func accept(_ datagram: Data, from source: VideoDatagramSocket.Source) {
        let frame = lock.withLock { () -> Frame? in
// Mutated in place rather than through a copy: the replay window is the state, and a probe
// replayed from a capture would otherwise be accepted as a fresh one.
            var opener = probeOpener
            defer { probeOpener = opener }
            return try? opener.open(datagram)
        }
        guard let frame else { return }

// Sealed through the lane's one sealer: the counter inside is the AEAD nonce, so a sealer of its
// own here would reuse one. Sent back the way the question came, because a question that arrived
// through the relay is a question about the relay's path.
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

// Every probe, not just the first: a NAT mapping that moves mid-session is the ordinary case this
// whole design is built around, and the address that just worked is the address to use.
        let moved = lock.withLock { () -> Bool in
            let changed = directPeer?.host != host || directPeer?.port != port
            directPeer = (host, port)
            return changed
        }
        guard moved else { return }

        do {
            try socket.setDirectPeer(host: host, port: port)
            videoLog.notice("the client is reachable directly at \(host, privacy: .public):\(port, privacy: .public)")
// Recorded and not said: the line above is this stage's sentence, and it names the address the
// probe actually arrived from rather than the one the relay remembered. This stops the next re-ask
// from announcing `probing` over a path that is already carrying the picture.
            _ = record(.open(peer: "\(host):\(port)"))
        } catch {
            videoLog.error("the client's direct address could not be used: \(error.localizedDescription, privacy: .public)")
            _ = record(.addressUnusable(peer: "\(host):\(port)"))
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
/// Called with the streamer's lock held, which is what keeps the chunk numbering of one frame from
/// being handed to another.
    func seal(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock { sealer.seal(kind: kind, payload: payload) }
    }

    /// Sends a group of datagrams and reports when the last one is away. The completion is the
    /// streamer's flow control, exactly as it is for a write to a connection.
    func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        socket.send(datagrams, completion: completion)
    }
}
