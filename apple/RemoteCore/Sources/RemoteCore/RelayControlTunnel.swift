import Foundation
import Network
import os

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
/// `NWParameters.tcp` cannot express `noDelay`, and Nagle delays each buffered write of the 60 Hz command stream by a round trip. Every relay socket goes through here.
private let videoTunnelLog = Logger(subsystem: "pl.dmq.peering", category: "relay-tunnel")

private func relayTCPParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    // Without it a relay that never answers the SYN holds the leg for the system default, over a minute.
    tcp.connectionTimeout = 10
    return NWParameters(tls: nil, tcp: tcp)
}

/// Writes the relay's 16-byte routing token first, then copies opaque TLS bytes, so TLS still owns the handshake end to end.
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
                    videoTunnelLog.error("could not route the relay's control connection, so it is being dropped: \(error.localizedDescription, privacy: .public)")
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
/// listener, which preserves the server role even though its internet socket is outbound.
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

    /// The source port of the loopback connection this bridge made, once it is up; the host matches it against the connection it accepts.
    public var localSourcePort: UInt16? { splice.localSourcePort }
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
    private var legs: [Leg] = []
    private let portLock = NSLock()
    private var _localSourcePort: UInt16?

    var localSourcePort: UInt16? { portLock.withLock { _localSourcePort } }

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
            if isLocal {
                localReady = true
                if case .hostPort(_, let port)? = local.currentPath?.localEndpoint {
                    portLock.withLock { _localSourcePort = port.rawValue }
                }
            } else {
                relayReady = true
            }
            advance()
        case .failed, .cancelled:
            stop()
        case .waiting(let error):
            // Not a failure: a relay leg with nowhere to go is a phone mid-handover, and the session's silence watchdog ends one that does not recover. Logged because waiting and fine look identical above this layer.
            videoTunnelLog.notice("the relay leg is waiting: \(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    private struct Leg {
        let source: NWConnection
        let destination: NWConnection
        var inFlightBytes = 0
        var reading = false
    }

    /// Two of the largest read buffers: a splice reading as fast as it can turns a slow receiver into an out-of-memory sender.
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

    /// The read is re-armed here, not in the send's completion, so a direction does not carry one buffer at a time. A send completion restarts a read stopped by a full window.
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
                    // Only a direction stopped by a full window reaches here: one still reading has a read outstanding and must not get a second.
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
