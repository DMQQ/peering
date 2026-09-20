import Foundation
import Network

public enum RelayTunnelError: LocalizedError, Sendable, Equatable {
    case invalidPort(UInt16)
    case listener(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "The relay supplied an invalid control port: \(port)."
        case .listener(let message): return "Could not open the local relay tunnel: \(message)"
        case .transport(let message): return "The relay control tunnel failed: \(message)"
        }
    }
}

/// TCP parameters for every socket on the relay path, with Nagle disabled.
///
/// `NWParameters.tcp` — the static factory — has no way to express `noDelay`, which is how the
/// relay path came to buffer every small write while the direct path had already stopped doing so.
/// It costs at least as much here as it did there: the same coalesced 60 Hz command stream crosses
/// these sockets, and Nagle holds a partial segment until the previous one is acknowledged, so on a
/// path whose RTT is tens of milliseconds each buffered write waits out a round trip before the next
/// cursor position leaves. The direct path measured 40 ms for exactly this.
///
/// Every socket below goes through here rather than reaching for `.tcp`.
private func relayTCPParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: nil, tcp: tcp)
}

/// Presents a loopback TCP endpoint backed by a routed socket to `peeringd`.
///
/// The existing client TLS transport connects to the loopback endpoint and still owns the TLS
/// handshake end to end. The proxy writes the relay's 16-byte routing token first, then copies the
/// opaque TLS bytes. This avoids teaching the security state machine anything about rendezvous.
public final class RelayControlProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.relay.client-tunnel")
    private let session: RelaySession
    private var listener: NWListener?
    private var splice: RelayByteSplice?

    public init(session: RelaySession) {
        self.session = session
    }

    public func start() async throws -> NWEndpoint {
        guard session.controlToken.count == 16 else { throw RelayProtocolError.invalidToken }
        let listener: NWListener
        do {
            let parameters = relayTCPParameters()
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw RelayTunnelError.listener(error.localizedDescription)
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShotContinuation(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        resumed.resume(throwing: RelayTunnelError.listener("No local port was assigned."))
                        return
                    }
                    resumed.resume(returning: .hostPort(host: "127.0.0.1", port: port))
                case .failed(let error):
                    resumed.resume(throwing: RelayTunnelError.listener(error.localizedDescription))
                    self.cancel()
                case .cancelled:
                    resumed.resume(throwing: RelayTunnelError.listener("The local listener stopped."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] local in
                guard let self else { local.cancel(); return }
                self.listener?.newConnectionHandler = nil
                self.listener?.cancel()
                self.listener = nil
                do {
                    let splice = try RelayByteSplice(
                        local: local,
                        relayHost: self.session.controlHost,
                        relayPort: self.session.controlPort,
                        token: self.session.controlToken,
                        queue: self.queue
                    )
                    self.splice = splice
                    splice.start()
                } catch {
                    local.cancel()
                }
            }
            listener.start(queue: queue)
        }
    }

    public func cancel() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            splice?.cancel()
            splice = nil
        }
    }
}

/// Copies a relay socket to a local TCP endpoint. The host points this at its existing TLS
/// listener, which preserves the crucial server role even though its internet socket is outbound.
public final class RelayControlBridge: @unchecked Sendable {
    private let splice: RelayByteSplice

    public init(
        session: RelaySession,
        localPort: UInt16,
        onClose: (@Sendable () -> Void)? = nil
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: localPort) else {
            throw RelayTunnelError.invalidPort(localPort)
        }
        let local = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: relayTCPParameters())
        splice = try RelayByteSplice(
            local: local,
            relayHost: session.controlHost,
            relayPort: session.controlPort,
            token: session.controlToken,
            queue: DispatchQueue(label: "pl.dmq.peering.relay.host-tunnel"),
            onStop: onClose
        )
    }

    public func start() { splice.start() }
    public func cancel() { splice.cancel() }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: any Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

/// Backpressured, bidirectional byte copying. All state lives on `queue`.
///
/// Internal rather than private so a test can drive it over loopback: the pipelined pump is
/// concurrent code, and the ways it can go wrong — a direction that stops reading, two reads
/// outstanding at once, a buffer dropped when the window is full — are not visible by reading it.
final class RelayByteSplice: @unchecked Sendable {
    private let local: NWConnection
    private let relay: NWConnection
    private let token: Data
    private let queue: DispatchQueue
    private let onStop: (@Sendable () -> Void)?
    private var localReady = false
    private var relayReady = false
    private var tokenSent = false
    private var pumping = false
    private var stopped = false
    /// The two directions, once both sockets are ready. Empty until then.
    private var legs: [Leg] = []

    init(
        local: NWConnection,
        relayHost: String,
        relayPort: UInt16,
        token: Data,
        queue: DispatchQueue,
        onStop: (@Sendable () -> Void)? = nil
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: relayPort) else {
            throw RelayTunnelError.invalidPort(relayPort)
        }
        self.local = local
        relay = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(relayHost), port: port),
            using: relayTCPParameters()
        )
        self.token = token
        self.queue = queue
        self.onStop = onStop
    }

    func start() {
        local.stateUpdateHandler = { [weak self] state in self?.state(state, isLocal: true) }
        relay.stateUpdateHandler = { [weak self] state in self?.state(state, isLocal: false) }
        local.start(queue: queue)
        relay.start(queue: queue)
    }

    func cancel() {
        queue.async { [self] in stop() }
    }

    private func state(_ state: NWConnection.State, isLocal: Bool) {
        switch state {
        case .ready:
            if isLocal { localReady = true } else { relayReady = true }
            advance()
        case .failed, .cancelled:
            stop()
        default:
            break
        }
    }

    /// One direction of the splice: where it reads, where it writes, and what is in flight.
    ///
    /// A type of its own because the two directions share nothing but the queue, and because the
    /// stop-and-wait bug this replaces was easiest to write when that state was implicit in the
    /// call chain.
    private struct Leg {
        let source: NWConnection
        let destination: NWConnection
        /// Bytes handed to the destination and not yet reported as sent.
        var inFlightBytes = 0
        /// Whether a read is already outstanding. Only one may be.
        var reading = false
    }

    /// How much one direction may have in flight before it stops reading.
    ///
    /// **The bound is what makes the pipeline safe rather than the pipeline itself.** The far end
    /// can be slower than the near one, and a splice that reads as fast as it can turns a slow
    /// receiver into an out-of-memory sender. Two of the largest buffers this reads at a time is
    /// enough to keep the pipe full across a round trip and small enough that the queue is not
    /// pretending to be a buffer.
    private static let maxInFlightBytes = 512 * 1024
    private static let readSize = 256 * 1024

    private func advance() {
        guard !stopped, localReady, relayReady else { return }
        guard !tokenSent else {
            guard !pumping else { return }
            pumping = true
            legs = [
                Leg(source: local, destination: relay),
                Leg(source: relay, destination: local),
            ]
            for index in legs.indices { pump(index) }
            return
        }
        tokenSent = true
        relay.send(content: token, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { self.advance() } else { self.stop() }
        })
    }

    /// Keeps one direction reading and writing at the same time.
    ///
    /// **The read is re-armed here, not inside the send's completion**, and that one line is the
    /// whole of the change. It used to be re-armed only after the previous buffer had been reported
    /// sent, so a direction carried one buffer at a time and the near socket sat undrained while
    /// each was in flight — a scheduling round trip added to every chunk, in both directions, for
    /// the life of the connection, on the channel that carries input. On a path whose round trip is
    /// already tens of milliseconds that is not a small share of it.
    ///
    /// Reading stops when the window is full, and a send completion starts it again — which is the
    /// only thing that would otherwise leave a direction stalled.
    private func pump(_ index: Int) {
        guard !stopped, legs.indices.contains(index) else { return }
        legs[index].reading = true
        let leg = legs[index]
        leg.source.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            self.legs[index].reading = false

            if let data, !data.isEmpty {
                self.legs[index].inFlightBytes += data.count
                leg.destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    self.legs[index].inFlightBytes -= data.count
                    if sendError != nil { self.stop(); return }
                    // Only reaches a direction that stopped reading because the window was full.
                    // One that is still reading has a read outstanding and must not be given a
                    // second one.
                    if !self.legs[index].reading { self.pump(index) }
                })
                if self.legs[index].inFlightBytes < Self.maxInFlightBytes {
                    self.pump(index)
                }
                return
            }

            if isComplete || error != nil { self.stop(); return }
            self.pump(index)
        }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        local.cancel()
        relay.cancel()
        onStop?()
    }
}
