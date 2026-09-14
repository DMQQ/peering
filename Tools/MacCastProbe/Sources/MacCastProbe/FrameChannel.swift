import Foundation
import Network
import RemoteCore

/// A framed connection with an awaitable inbox.
///
/// This is the probe's counterpart to the host's `PeerConnection`, but shaped for a
/// straight-line script: the script says "send this, then wait for the next frame" and
/// this type handles the fact that TCP delivers neither on those terms.
final class FrameChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.maccast.probe")

    private var connection: NWConnection?
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var inbox: [Frame] = []
    private var waiter: CheckedContinuation<Frame, Error>?
    private var failure: Error?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    private(set) var observedServerKey: Data?

    var negotiatedTLSVersion: String {
        guard let connection,
              let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return "—" }

        switch sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        default: return "unknown"
        }
    }

    // MARK: - Connect

    func connect(
        host: String,
        port: UInt16,
        clientIdentity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        observed: TLSConfig.ObservedKey,
        timeout: TimeInterval
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Probe.ProbeError(message: "\(port) is not a valid port")
        }
        try await connect(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
            clientIdentity: clientIdentity,
            pinnedServerKey: pinnedServerKey,
            observed: observed,
            timeout: timeout
        )
    }

    /// Connects through a Bonjour endpoint discovered by ``HostBrowser``. Prefer this over
    /// host/port: the endpoint carries the interface the host was found on, so the
    /// connection takes the path that actually works on a machine with several.
    func connect(
        endpoint: NWEndpoint,
        clientIdentity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        observed: TLSConfig.ObservedKey,
        timeout: TimeInterval
    ) async throws {
        let tls = TLSConfig.clientOptions(
            identity: clientIdentity,
            pinnedServerKey: pinnedServerKey,
            observed: observed,
            queue: queue
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        // The TLS verify block runs on this queue and records the server key. Reading it
        // back here is safe only because the handshake has completed by the time `.ready`
        // fires — before that the block may not have run yet.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { readyContinuation = continuation }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    observedServerKey = observed.value
                    resumeReady(.success(()))
                    receiveNext()
                case .failed(let error):
                    resumeReady(.failure(error))
                    finish(error)
                case .cancelled:
                    resumeReady(.failure(Probe.ProbeError(message: "connection cancelled")))
                    finish(Probe.ProbeError(message: "connection cancelled"))
                case .waiting(let error):
                    // Connection refused arrives as `.waiting`, not `.failed`, because
                    // Network.framework would otherwise retry forever. For a probe that is
                    // indistinguishable from a hang, so treat it as terminal.
                    resumeReady(.failure(error))
                    finish(error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        // A connection that is never accepted would otherwise park here until the shell
        // times out, with no indication of which step stalled. The handle is kept so a
        // run that ends normally does not leave a timer behind to fail it after the fact.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(Probe.ProbeError(message: "timed out after \(Int(timeout))s waiting for a frame"))
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        connection?.cancel()
    }

    /// Stands the frame-wait watchdog down, for a caller that imposes a deadline of its own.
    ///
    /// The watchdog is a fixed `timeout` set at connect time, so a caller whose deadline is
    /// longer than it — `--video-recv-seconds` beyond `--timeout` — would be interrupted
    /// mid-window by "timed out waiting for a frame". That message is indistinguishable from
    /// the real thing, so the window owner has to be the only clock.
    func clearTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: - Frames

    func send(_ frame: Frame) {
        connection?.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    /// The next whole frame, or an error if the connection ends first.
    func next() async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            // Only one outstanding read at a time: the script is strictly send-then-receive,
            // so a second waiter would mean the script itself is confused, and silently
            // clobbering the first would turn that into a hang.
            guard waiter == nil else {
                lock.unlock()
                continuation.resume(throwing: Probe.ProbeError(message: "two reads outstanding at once"))
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    // MARK: - Receive loop

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let frames: [Frame]
                do {
                    frames = try appendAndDrain(data)
                } catch {
                    finish(error)
                    connection?.cancel()
                    return
                }
                for frame in frames { deliver(frame) }
            }

            if let error { finish(error); return }
            if isComplete { finish(Probe.ProbeError(message: "host closed the connection")); return }
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

    private func deliver(_ frame: Frame) {
        // An error frame is always terminal — the host sends it immediately before closing
        // — so it is raised as the failure rather than returned as an ordinary frame the
        // script would have to remember to check for. Frames are delivered before the
        // receive loop acts on `isComplete`, so this wins the race against the close.
        if frame.kind == .error {
            let message = (try? MessageCodec.decode(ErrorPayload.self, from: frame.payload))?.message
                ?? "unspecified error"
            finish(Probe.ProbeError(message: "host refused: \(message)"))
            return
        }

        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
            return
        }
        inbox.append(frame)
        lock.unlock()
    }

    /// Whether the peer ended the connection, as opposed to it still being open.
    ///
    /// Needed to tell a host that *refused* a connection from one that accepted it and
    /// simply has nothing to say yet. Every read on an accepted-but-idle connection hangs
    /// until the timeout, and every read on a refused one fails immediately — without this
    /// flag the two are the same shape, and the difference is the whole test.
    var hasEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failure != nil
    }

    private func finish(_ error: Error) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
