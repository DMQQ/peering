import Foundation
import PeeringKit
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// The relay's datagram path, as the video pipeline sees it: a socket to send on, and the sealing
/// that makes what goes out unreadable to the relay in the middle.
final class VideoDatagramLane: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: VideoDatagramSocket
    private var sealer: VideoDatagramSealer

/// Opens what the client seals, which in this direction means one thing: a probe.
    private var probeOpener: VideoDatagramOpener

    private var directPeer: (host: String, port: UInt16)?

/// Where pointer movement that arrived straight from the client is applied.
    var onInput: (@Sendable (RemoteCommand) -> Void)?
    private var inputOrder = DirectInputOrder()
    /// What the direct path pressed and has not released, so closing the lane lets go of it as the control connection does.
    private var heldInput = HeldInputLedger()

/// What the attempt has come to, so that it can be said once per change rather than per probe.
    private var probeStatus: ClientSession.DirectPath = .notTried

    var isDirectOpen: Bool {
        lock.withLock {
            if case .open = probeStatus { return true }
            return false
        }
    }

/// The last discovery that threw, kept so that one is said once rather than on every re-ask.
    private var discoveryFailure: String?

    private let relay: RelaySession
    private let announcesCandidates: Bool
    private let controlBridge: RelayControlBridge?
    private var portMapping: UDPPortMapping?
    /// The public address the router forwards to this Mac, once it has said.
    private var mappedAddress: String?

    private var probeTask: Task<Void, Never>?
    private var networkObserver: NetworkChangeObserver?
    /// Once the lane has failed or been cancelled, no later race may install a fresh probe task.
    private var stopped = false

/// - Throws: when the relay's allocation cannot be used: a token that is not the size the wire
///   contract fixes it at, or a port that is not a port. The caller refuses the request rather
///   than reporting a lane that cannot carry anything.
    init(relay: RelaySession, secret: Data, announcesCandidates: Bool, controlBridge: RelayControlBridge?) throws {
        self.relay = relay
        self.controlBridge = controlBridge
        self.announcesCandidates = announcesCandidates
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

    func start() {
        socket.onFailure = { [weak self] error in
            videoLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
            self?.stopProbing()
        }
        socket.onDatagram = { [weak self] datagram, source in
            self?.accept(datagram, from: source)
        }
        socket.start()
        controlBridge?.attachDirect(
            send: { [weak self] frame in
                guard let self else { return }
                let sealed = self.seal(kind: .controlPipe, payload: frame)
                if !sealed.isEmpty { self.socket.sendDirect(sealed) { _ in } }
            },
            isLive: { [weak self] in self?.socket.pathIsLive == true }
        )
        beginDirectPath()
        beginPortMapping()
        let observer = NetworkChangeObserver { [weak self] in self?.networkChanged() }
        let kept = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            networkObserver = observer
            return true
        }
        if !kept { observer.cancel() }
    }

    /// The path that was proven belonged to the old network: forget it and knock afresh, quickly.
    private func networkChanged() {
        lock.withLock { directPeer = nil }
        socket.pathChanged()
        beginDirectPath()
    }

    private func beginPortMapping() {
        guard announcesCandidates else { return }
        let mapping = UDPPortMapping(internalPort: socket.localPort) { [weak self] address in
            self?.lock.withLock { self?.mappedAddress = address }
        }
        // A lane already stopped has no later call to stop what is started here.
        let kept = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            portMapping = mapping
            return true
        }
        if kept { mapping.start() }
    }

    /// Tells the client where the router forwards to this Mac, through the relay lane it already has: a client that cannot punch to this Mac can still send to that address.
    private func announceCandidates() {
        guard announcesCandidates else { return }
        let announcement = DirectCandidates.announcement(
            mapped: lock.withLock { mappedAddress },
            pathIsOpen: socket.pathIsLive
        )
        guard let announcement, let payload = try? MessageCodec.encode(announcement) else { return }
        let sealed = seal(kind: .directCandidates, payload: payload)
        if !sealed.isEmpty { socket.send(sealed) { _ in } }
    }

/// Asks the relay where the client is, and then keeps knocking on its door.
    private func beginDirectPath() {
        let task = Task { [weak self] in
            guard let self else { return }
            let relay = self.relay
            let lookup = RelayPeerLookup(url: ProtocolInfo.relaySignallingURL)

// Quick while there is any prospect of it working, then slow for the rest of the session: the
// fast phase is what opens the path, and the slow one recovers a mapping that expired.
            var schedule = DirectPathSchedule()
            while !Task.isCancelled {
                // Not while the path is carrying traffic: the relay's view of the client is the address it was punched at, and a client behind an address-dependent NAT answers from another one.
                if schedule.asksRelayForPeerAddress, !socket.pathIsLive {
                    do {
                        if let address = try await lookup.address(videoToken: relay.videoToken) {
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
                self.announceCandidates()
                schedule.probeSent()
                if schedule.verdictIsDue(now: .now) {
                    self.note(self.lock.withLock { self.probeStatus }.verdict())
                }
                try? await Task.sleep(for: schedule.intervalToNextProbe)
            }
            await lookup.close()
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
    private func record(_ outcome: ClientSession.DirectPath) -> Bool {
        lock.withLock {
            guard let next = probeStatus.updated(with: outcome) else { return false }
            probeStatus = next
            return true
        }
    }

/// Records what the attempt has come to, and says it when that is news.
    @discardableResult
    private func note(_ outcome: ClientSession.DirectPath) -> Bool {
        guard record(outcome) else { return false }
        videoLog.notice("direct path: \(Self.sentence(for: outcome), privacy: .public)")
        return true
    }

/// The outcome in this end's words.
    private static func sentence(for outcome: ClientSession.DirectPath) -> String {
        switch outcome {
        case .notTried: return "Not tried"
        case .noAddress: return "The relay has not said where the client is"
        case .probing(let peer): return "Knocking on \(peer), nothing back yet"
        case .addressUnusable(let peer): return "The relay named \(peer), which this Mac cannot use"
        case .open(let peer): return "Straight to \(peer)"
        case .gaveUp(.relayHasNoAddress): return "The relay never learned where the client is"
        case .gaveUp(.noAnswer(let peer)): return "Knocked on \(peer) for \(Int(ClientSession.DirectPath.verdictAfter)) seconds with no answer: a NAT or firewall on one side is blocking it"
        }
    }

    private func clearDiscoveryFailure() {
        lock.withLock { discoveryFailure = nil }
    }

/// Says a discovery that threw, once rather than on every re-ask.
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
    private func accept(_ datagram: Data, from source: VideoDatagramSocket.Source) {
        let frame = lock.withLock { () -> Frame? in
// Mutated in place rather than through a copy: the replay window is the state, and a probe
// replayed from a capture would otherwise be accepted as a fresh one.
            var opener = probeOpener
            defer { probeOpener = opener }
            return try? opener.open(datagram)
        }
        guard let frame else { return }
        if case .peer(let host, let port) = source { confirmPeer(host: host, port: port) }

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

        if frame.kind == .controlPipe {
            controlBridge?.receiveDirect(frame.payload)
            return
        }

        if frame.kind == .directCommand {
            receiveDirectCommand(frame, from: source)
            return
        }

    }

/// An authenticated datagram arrived from this address: the picture goes back to it, and the path counts as live.
    private func confirmPeer(host: String, port: UInt16) {
        do {
            try socket.adoptPeer(host: host, port: port)
        } catch {
            Analytics.failed(error, in: .network, context: ["operation": "use client direct address"])
            videoLog.error("the client's direct address could not be used: \(error.localizedDescription, privacy: .public)")
            _ = record(.addressUnusable(peer: "\(host):\(port)"))
            return
        }
        let moved = lock.withLock { () -> Bool in
            let changed = directPeer?.host != host || directPeer?.port != port
            directPeer = (host, port)
            return changed
        }
        guard moved else { return }
        videoLog.notice("the client is reachable directly at \(host, privacy: .public):\(port, privacy: .public)")
        _ = record(.open(peer: "\(host):\(port)"))
    }

/// Applied only from the address already proven by a probe, and only for the commands a loss or a reordering cannot hurt.
    private func receiveDirectCommand(_ frame: Frame, from source: VideoDatagramSocket.Source) {
        guard case .peer(let host, let port) = source,
              let message = try? MessageCodec.decode(DirectCommand.self, from: frame.payload),
              DirectCommand.isEligible(message.command)
        else { return }
        let apply: (@Sendable (RemoteCommand) -> Void)? = lock.withLock {
            guard directPeer?.host == host, directPeer?.port == port,
                  inputOrder.accepts(message.sequence)
            else { return nil }
            heldInput.observe(message.command)
            return onInput
        }
        apply?(message.command)
    }

    func cancel() {
        let release = lock.withLock { () -> (commands: [RemoteCommand], apply: (@Sendable (RemoteCommand) -> Void)?) in
            (heldInput.releaseCommands(), onInput)
        }
        for command in release.commands { release.apply?(command) }
        stopProbing()
        socket.cancel()
    }

    private func stopProbing() {
        let (task, mapping, observer) = lock.withLock { () -> (Task<Void, Never>?, UDPPortMapping?, NetworkChangeObserver?) in
            stopped = true
            let task = probeTask
            let mapping = portMapping
            let observer = networkObserver
            probeTask = nil
            portMapping = nil
            networkObserver = nil
            return (task, mapping, observer)
        }
        task?.cancel()
        mapping?.stop()
        observer?.cancel()
    }

    var sentDatagrams: Int { socket.sentDatagrams }

    func setParityGroup(_ group: Int) {
        lock.withLock { sealer.parityGroup = ParityPolicy.clamped(group) }
    }

    func seal(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock { sealer.seal(kind: kind, payload: payload) }
    }

    func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        socket.send(datagrams, completion: completion)
    }
}
