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
private final class RelayByteSplice: @unchecked Sendable {
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

    private func advance() {
        guard !stopped, localReady, relayReady else { return }
        guard !tokenSent else {
            guard !pumping else { return }
            pumping = true
            pump(from: local, to: relay)
            pump(from: relay, to: local)
            return
        }
        tokenSent = true
        relay.send(content: token, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { self.advance() } else { self.stop() }
        })
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError == nil, !isComplete, error == nil {
                        self.pump(from: source, to: destination)
                    } else {
                        self.stop()
                    }
                })
                return
            }
            if isComplete || error != nil { self.stop(); return }
            self.pump(from: source, to: destination)
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
