import Foundation
import Network
import Security
import os

private let transportLog = Logger(subsystem: "pl.dmq.peering", category: "client")

/// Where a client keeps the hosts it has paired with, keyed by the host's `serverID`.
///
/// On iOS the item is `…ThisDeviceOnly`: a pin restored onto a different device would hand this
/// device's trust to whoever restored the backup.
public final class ClientPinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private let account: String
    private var pins: [String: Data]

    public static let standard = ClientPinStore(service: "pl.dmq.peering.client.pins")

    public init(service: String, account: String = "paired-hosts") {
        self.service = service
        self.account = account
        pins = Self.read(service: service, account: account)
    }

    public var hostIDs: [String] { lock.withLock { pins.keys.sorted() } }
    public var isEmpty: Bool { lock.withLock { pins.isEmpty } }

    public func pin(for hostID: String) -> Data? { lock.withLock { pins[hostID] } }

    public func contains(publicKey: Data) -> Bool {
        lock.withLock { pins.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// - Returns: `false` if the Keychain write failed, in which case the caller must not report a
    ///   successful pairing: the user would be asked to pair again on the very next connection.
    @discardableResult
    public func record(hostID: String, publicKey: Data) -> Bool {
        lock.withLock {
            let previous = pins[hostID]
            pins[hostID] = publicKey
            guard Self.write(pins, service: service, account: account) else {
                if let previous { pins[hostID] = previous } else { pins.removeValue(forKey: hostID) }
                return false
            }
            return true
        }
    }

    @discardableResult
    public func remove(hostID: String) -> Bool {
        lock.withLock {
            let previous = pins.removeValue(forKey: hostID)
            guard Self.write(pins, service: service, account: account) else {
                if let previous { pins[hostID] = previous }
                return false
            }
            return true
        }
    }

    @discardableResult
    public func removeAll() -> Bool {
        lock.withLock {
            pins.removeAll()
            return Self.write(pins, service: service, account: account)
        }
    }

    private static var accessibility: CFString {
        #if os(iOS)
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        return kSecAttrAccessibleAfterFirstUnlock
        #endif
    }

    private static func read(service: String, account: String) -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(SecretStore.attributes(query), &item)

        guard status == errSecSuccess else {
            // errSecItemNotFound is the ordinary first-run case. Anything else means the store
            // exists but is unreadable, which is indistinguishable from an empty one: every paired
            // Mac would silently become a stranger and the user would be asked to pair again.
            if status != errSecItemNotFound {
                transportLog.error("could not read client pins: OSStatus \(status, privacy: .public)")
            }
            return [:]
        }

        guard let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else {
            transportLog.error("client pin store exists but could not be decoded; treating as empty")
            return [:]
        }
        return decoded
    }

    private static func write(_ pins: [String: Data], service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pins) else {
            transportLog.error("could not encode client pins")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemUpdate(
            SecretStore.attributes(query),
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            transportLog.error("could not update client pins: OSStatus \(status, privacy: .public)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(SecretStore.attributes(insert), nil)
        if addStatus != errSecSuccess {
            transportLog.error("could not add client pins: OSStatus \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}

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

    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var closedReason: Failure?
    private var timeoutTask: Task<Void, Never>?
    private var observed: TLSConfig.ObservedKey?
    private var _observedServerKey: Data?
    private var _tlsVersion = "None"

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
                        self.cancelTimeout()
                        self.resumeReady(.failure(failure))
                        self.finish(failure)
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
        connection = nil
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

/// Rate-limits and merges outgoing commands so a 120 Hz touch stream does not flood the link.
///
/// - Absolute positions (`.mouseMove`) are superseded by a newer sample and replaced in place, the
///   original slot being kept so a coalesced move cannot jump ahead of an already-queued command.
/// - Relative deltas (`.joystickMove`, `.scroll`) are summed, never dropped, or a fast flick would
///   arrive as a single small nudge.
/// - Everything else goes out as it is produced, since a dropped `mouseUp` leaves a button stuck down.
///
/// The output rate is bounded by `interval` (60 Hz by default), except that a command arriving when
/// nothing has been sent for a full interval goes out immediately, without which a single tap would
/// wait up to 16 ms before its cursor move left.
public final class CommandCoalescer: @unchecked Sendable {
    public let interval: TimeInterval

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let sink: @Sendable (RemoteCommand) -> Void

    private var pending: [RemoteCommand] = []
    private var lastFlush: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    public init(
        interval: TimeInterval = 1.0 / 60.0,
        queue: DispatchQueue = DispatchQueue(label: "pl.dmq.peering.commands"),
        sink: @escaping @Sendable (RemoteCommand) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.sink = sink
    }

    deinit { timer?.cancel() }

/// Arms the trailing-edge timer, if there is anything for it to send. A timer with an empty queue
/// is a pointless 60 Hz wake-up for the life of a session. Idempotent.
    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        guard !pending.isEmpty else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        // A little leeway: this is a stream of cursor positions, and waking the CPU at an
        // exact 16.6 ms boundary costs power for a frame the eye cannot distinguish.
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.flush() }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    public func enqueue(_ command: RemoteCommand) {
        lock.lock()
        insert(command)
        let due = command.coalescing == .none || now() - lastFlush >= interval
        let batch = due ? drain() : []
        let waiting = !pending.isEmpty
        lock.unlock()

        for item in batch { sink(item) }
        if waiting { start() }
    }

/// Sends whatever is pending. Disarms the timer when the queue comes back empty.
    public func flush() {
        lock.lock()
        let batch = drain()
        let idle = pending.isEmpty
        lock.unlock()
        for item in batch { sink(item) }
        if idle { stop() }
    }

    // MARK: - Queue handling (call with `lock` held)

    private func insert(_ command: RemoteCommand) {
        switch command.coalescing {
        case .none:
            pending.append(command)

        case .replaceLatest:
            // Replaced in place: appending would reorder the move ahead of commands queued before
            // it, which for a move-then-click pair means clicking at the previous position.
            if let index = pending.firstIndex(where: { Self.sameShape($0, command) }) {
                pending[index] = command
            } else {
                pending.append(command)
            }

        case .accumulate:
            if let index = pending.firstIndex(where: { Self.sameShape($0, command) }),
               let merged = Self.merge(pending[index], command) {
                pending[index] = merged
            } else {
                pending.append(command)
            }
        }
    }

    private func drain() -> [RemoteCommand] {
        guard !pending.isEmpty else { return [] }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lastFlush = now()
        return batch
    }

    private func now() -> TimeInterval {
        // `DispatchTime` rather than `Date`: this measures an interval, and a wall clock can
        // step backwards when the device syncs its time mid-gesture.
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Case-level, not value-level: two `.mouseMove`s collapse, but a `.mouseMove` and a
    /// `.joystickMove` are different channels of control and must not.
    private static func sameShape(_ lhs: RemoteCommand, _ rhs: RemoteCommand) -> Bool {
        switch (lhs, rhs) {
        case (.mouseMove, .mouseMove): return true
        case (.joystickMove, .joystickMove): return true
        case (.scroll, .scroll): return true
        default: return false
        }
    }

    private static func merge(_ older: RemoteCommand, _ newer: RemoteCommand) -> RemoteCommand? {
        switch (older, newer) {
        case (.joystickMove(let x1, let y1), .joystickMove(let x2, let y2)):
            return .joystickMove(dx: x1 + x2, dy: y1 + y2)
        case (.scroll(let x1, let y1), .scroll(let x2, let y2)):
            return .scroll(dx: x1 + x2, dy: y1 + y2)
        default:
            return nil
        }
    }
}
