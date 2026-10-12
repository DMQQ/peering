import Foundation
import Network
import Security
import os

let transportLog = Logger(subsystem: "pl.dmq.peering", category: "client")

/// One framed TLS connection to a host, in either role.
///
/// Deliberately not an actor: the app target defaults to `MainActor` isolation, and a video frame
/// arriving on the main thread is a stutter in the UI that is trying to draw it.
public final class ClientConnection: @unchecked Sendable {
    public enum Failure: LocalizedError, Sendable, Equatable {
        case invalidPort(UInt16)
        case timedOut(TimeInterval)
        case cancelled
        case hostClosed
        case refused(String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "\(port) is not a usable TCP port."
            case .timedOut(let seconds):
                return "Timed out after \(Int(seconds))s waiting for the Mac to answer."
            case .cancelled:
                return "Connection cancelled."
            case .hostClosed:
                return "The Mac closed the connection."
            case .refused(let message):
                return "The Mac refused the session: \(message)"
            case .transport(let message):
                return message
            }
        }
    }

    private let queue: DispatchQueue
    private let lock = NSLock()

    private var _connection: NWConnection?

    /// Read on whichever thread asks (a foreground check, a send) while the network queue clears it in `finish`, so every access takes the lock: an unguarded class reference torn between the two is a use after free.
    private var connection: NWConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
    private var decoder = FrameDecoder()
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var closedReason: Failure?
    private var timeoutTask: Task<Void, Never>?
    private var observed: TLSConfig.ObservedKey?
    private var _observedServerKey: Data?
    private var _tlsVersion = "None"
    private var _errorDetail: TransportErrorDetail?

    private var _onFrame: (@Sendable (Frame) -> Void)?
    private var _onClose: (@Sendable (Failure) -> Void)?

    /// Every whole frame the host sends. Invoked on the connection's own queue, never on the
    /// main actor, so a handler must hop deliberately before touching UI state.
    public var onFrame: (@Sendable (Frame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    public var onClose: (@Sendable (Failure) -> Void)? {
        get { lock.withLock { _onClose } }
        set { lock.withLock { _onClose = newValue } }
    }

    public var observedServerKey: Data? { lock.withLock { _observedServerKey } }

    public var negotiatedTLSVersion: String { lock.withLock { _tlsVersion } }

    /// The Network.framework error that ended this connection, if one did. Kept apart from ``Failure`` so that case stays a message.
    public var errorDetail: TransportErrorDetail? { lock.withLock { _errorDetail } }

    private func noteErrorDetail(_ error: Error) {
        guard let detail = TransportErrorDetail(error) else { return }
        lock.withLock { _errorDetail = detail }
    }

/// The address this connection was made to. A Bonjour endpoint carries the interface the host was
/// discovered on, which resolving it would lose.
    public var currentEndpoint: NWEndpoint? { connection?.endpoint }

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    // MARK: - Connect

    public func connect(
        to endpoint: NWEndpoint,
        identity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        let observed = TLSConfig.ObservedKey()
        self.observed = observed

        let tls = TLSConfig.clientOptions(
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            observed: observed,
            queue: queue
        )
        let tcp = NWProtocolTCP.Options()
        // Nagle buffers small packets for up to 40 ms looking for more to coalesce, which on a LAN
        // is pure latency added to every mouse move and keystroke.
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        try await start(NWConnection(to: endpoint, using: parameters), timeout: timeout)
    }

    public func connect(
        host: String,
        port: UInt16,
        identity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.invalidPort(port)
        }
        let observed = TLSConfig.ObservedKey()
        self.observed = observed

        let tls = TLSConfig.clientOptions(
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            observed: observed,
            queue: queue
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        try await start(
            NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: parameters),
            timeout: timeout
        )
    }

    private func start(_ connection: NWConnection, timeout: TimeInterval) async throws {
        self.connection = connection

// The connect deadline is armed before the connection starts: a host on the same machine reaches
// `.ready` while `connection.start` is still on the stack, so a later timer would fire into a healthy session.
        let handle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finishIfOpen(Failure.timedOut(timeout))
        }
        lock.withLock { timeoutTask = handle }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { readyContinuation = continuation }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.cancelTimeout()
                        // The verify block has run by now, so the observed key is final.
                        // Reading it earlier would race the TLS handshake.
                        self.lock.withLock {
                            self._observedServerKey = self.observed?.value
                            self._tlsVersion = Self.tlsVersion(of: connection)
                        }
                        self.resumeReady(.success(()))
                        self.receiveNext()
                    case .failed(let error):
                        transportLog.error("connection failed: \(String(describing: error), privacy: .public)")
                        let failure = Failure.transport(NetworkFailureText.describe(error))
                        self.noteErrorDetail(error)
                        self.cancelTimeout()
                        self.resumeReady(.failure(failure))
                        self.finish(failure)
                    case .cancelled:
                        self.cancelTimeout()
                        self.resumeReady(.failure(Failure.cancelled))
                        self.finish(Failure.cancelled)
                    case .waiting(let error):
                        // A refused connection arrives as `.waiting`, not `.failed`, because
                        // Network.framework would otherwise retry forever, which for a user who just
                        // tapped a Mac in a list is a hang.
                        transportLog.error("connection waiting: \(String(describing: error), privacy: .public)")
                        let failure = Failure.transport(NetworkFailureText.describe(error))
                        self.noteErrorDetail(error)
                        self.cancelTimeout()
                        self.resumeReady(.failure(failure))
                        self.finish(failure)
                        // `finish` drops the reference, so without this the waiting connection is never cancelled and outlives its session.
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } catch {
            cancelTimeout()
            throw error
        }
    }

    public func cancel() {
        cancelTimeout()
        connection?.cancel()
    }

    private func cancelTimeout() {
        let handle = lock.withLock { () -> Task<Void, Never>? in
            let task = timeoutTask
            timeoutTask = nil
            return task
        }
        handle?.cancel()
    }

    // MARK: - Send

    public func send(_ frame: Frame) {
        guard let connection else { return }
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

/// Encodes and sends a command. An encode failure is a programming error, so it is logged, not thrown.
    public func send(_ command: RemoteCommand) {
        do {
            send(Frame(kind: .command, payload: try MessageCodec.encode(command)))
        } catch {
            transportLog.error("could not encode \(String(describing: command), privacy: .public): \(error)")
        }
    }

    public func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        do {
            send(Frame(kind: kind, payload: try MessageCodec.encode(value)))
        } catch {
            transportLog.error("could not encode a \(String(describing: kind), privacy: .public) payload")
        }
    }

    // MARK: - Receive

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let frames: [Frame]
                do {
                    frames = try appendAndDrain(data)
                } catch {
                    // A framing error is unrecoverable, the byte stream being unusable, so the
                    // connection is torn down rather than resynchronised onto a guess.
                    transportLog.error("framing failed: \(String(describing: error), privacy: .public)")
                    let failure = Failure.transport(NetworkFailureText.describe(error))
                    connection?.cancel()
                    finish(failure)
                    return
                }
                let handler = lock.withLock { _onFrame }
                for frame in frames { handler?(frame) }
            }

            if let error {
                transportLog.error("receive failed: \(String(describing: error), privacy: .public)")
                noteErrorDetail(error)
                finish(.transport(NetworkFailureText.describe(error)))
                return
            }
            if isComplete {
                finish(.hostClosed)
                return
            }
            receiveNext()
        }
    }

    private func appendAndDrain(_ data: Data) throws -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        decoder.append(data)
        var frames: [Frame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }

    // MARK: - Termination

    /// Ends the connection with `failure`, once. The first reason wins: the host's explanation
    /// arrives before its close, and "connection reset" would throw away the only useful message.
    private func finish(_ failure: Failure) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        closedReason = failure
        let pending = readyContinuation
        readyContinuation = nil
        let handler = _onClose
        // A finished transport must not keep its callbacks (or the object graph behind them)
        // alive. In particular, a callback is allowed to mention its owning session.
        _onFrame = nil
        _onClose = nil
        _connection = nil
        lock.unlock()

        pending?.resume(throwing: failure)
        handler?(failure)
    }

    private func finishIfOpen(_ failure: Failure) {
        lock.lock()
        let alreadyClosed = closedReason != nil
        lock.unlock()
        guard !alreadyClosed else { return }
        connection?.cancel()
        finish(failure)
    }

    private func resumeReady(_ result: Result<Void, any Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func tlsVersion(of connection: NWConnection) -> String {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata
        else { return "None" }

        switch sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        default: return "unknown"
        }
    }
}
