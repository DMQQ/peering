import Foundation
import Network
import Security
import os

private let transportLog = Logger(subsystem: "pl.dmq.peering", category: "client")

/// Where a client keeps the hosts it has paired with.
///
/// The same trust store as the host's ``PinStore``, but with one difference that matters on
/// iOS: the item is written `…ThisDeviceOnly`, so the pin is excluded from iCloud Keychain
/// and from encrypted backups. That is deliberate and not paranoia. A pin decides which Mac
/// this device will drive, and a pin that could be restored onto a *different* device would
/// hand that trust to whoever restored the backup — carrying a pairing across devices is
/// exactly the property that should require pairing again.
///
/// Keys are the host's `serverID` (its Bonjour device ID), which is stable across networks
/// and DHCP leases, so a pin survives the Mac changing address.
public final class ClientPinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private let account: String
    private var pins: [String: Data]

    /// The store the app uses. A separate instance is made for tests and tooling, so a
    /// probe run cannot disturb what the real client believes.
    public static let standard = ClientPinStore(service: "pl.dmq.peering.client.pins")

    public init(service: String, account: String = "paired-hosts") {
        self.service = service
        self.account = account
        pins = Self.read(service: service, account: account)
    }

    public var hostIDs: [String] { lock.withLock { pins.keys.sorted() } }
    public var isEmpty: Bool { lock.withLock { pins.isEmpty } }

    public func pin(for hostID: String) -> Data? { lock.withLock { pins[hostID] } }

    /// Whether *any* paired host matches this public key. Used to recognise a Mac whose ID
    /// changed, so the client can say "this is a Mac you know under a new name" rather than
    /// silently treating it as a stranger.
    public func contains(publicKey: Data) -> Bool {
        lock.withLock { pins.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// - Returns: `false` if the Keychain write failed. The caller must not report a
    ///   successful pairing in that case — the user would be told they are paired and then
    ///   be asked to pair again on the very next connection.
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

    /// `…ThisDeviceOnly` on iOS, per the reasoning in the type comment. macOS keeps its
    /// existing item class, where the data-protection keychain behaves differently and
    /// `ThisDeviceOnly` buys nothing a FileVault-protected login keychain does not.
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            // errSecItemNotFound is the ordinary first-run case. Anything else means the
            // store exists but is unreadable — and an unreadable store is indistinguishable
            // from an empty one, so every paired Mac would silently become a stranger and
            // the user would be asked to pair again with no explanation.
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
            query as CFDictionary,
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
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            transportLog.error("could not add client pins: OSStatus \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}

/// One framed TLS connection to a host, in either role.
///
/// The client's counterpart to the host's `PeerConnection`, and the same shape on purpose:
/// frames in through a callback, frames out through a queue, and a decoder that makes no
/// assumption about how TCP splits them.
///
/// Deliberately *not* an actor. Both connections run off the network, on their own queues,
/// and neither may be bound to the main actor — the app target defaults to `MainActor`
/// isolation, and a video frame arriving on the main thread is a dropped frame and a stutter
/// in the UI that is trying to draw it.
public final class ClientConnection: @unchecked Sendable {
    public enum Failure: LocalizedError, Sendable, Equatable {
        case invalidPort(UInt16)
        case timedOut(TimeInterval)
        case cancelled
        case hostClosed
        /// The host sent an `error` frame and then closed. Carries its explanation.
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

    /// Invoked once, when the connection ends for any reason.
    public var onClose: (@Sendable (Failure) -> Void)? {
        get { lock.withLock { _onClose } }
        set { lock.withLock { _onClose = newValue } }
    }

    /// The host's identity key as observed in its TLS certificate. `nil` until the handshake
    /// completes; for a first pairing this is the value the SAS comparison authenticates.
    public var observedServerKey: Data? { lock.withLock { _observedServerKey } }

    public var negotiatedTLSVersion: String { lock.withLock { _tlsVersion } }

    /// The address this connection was made to.
    ///
    /// Read back from the connection rather than remembered by the caller, which is what
    /// lets the *second* socket be opened to exactly the same place: a Bonjour endpoint
    /// still carries the interface the host was discovered on, and resolving it to an
    /// address first would throw that away.
    public var currentEndpoint: NWEndpoint? { connection?.endpoint }

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    // MARK: - Connect

    /// Connects to a host found over Bonjour.
    ///
    /// Preferred over host/port because the endpoint carries the interface the host was
    /// discovered on, so the connection takes the path that actually works on a machine with
    /// several.
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
        // Nagle's algorithm buffers small packets for up to 40 ms looking for more data to
        // coalesce. On a LAN where RTT is under 1 ms this is pure latency added to every
        // mouse move and keystroke. Disable it so each command goes out the moment it is
        // produced rather than waiting for the coalescing window to expire.
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        try await start(NWConnection(to: endpoint, using: parameters), timeout: timeout)
    }

    /// Connects to a literal address. The simulator path, and the fallback when Bonjour is
    /// unavailable — which on iOS is the common case rather than the exotic one.
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

        // The connect deadline, armed **before** the connection is started.
        //
        // Without this a connection to a host that accepts the socket and then never speaks
        // parks the UI on "connecting" indefinitely, with nothing to show the user.
        //
        // Armed here rather than after the handshake below completes, because a host on the
        // same machine — or any host worth using — reaches `.ready` while `connection.start`
        // is still on the stack. A timer created afterwards would be born already-unnecessary,
        // the cancel would find nothing to cancel, and the deadline would then fire `timeout`
        // seconds into a healthy session. That reads as the Mac hanging up mid-handshake, and
        // it happens exactly when someone takes longer than the timeout to compare the pairing
        // digits — which is the one moment a user is *expected* to be slow.
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
                        let failure = Failure.transport(error.localizedDescription)
                        self.cancelTimeout()
                        self.resumeReady(.failure(failure))
                        self.finish(failure)
                    case .cancelled:
                        self.cancelTimeout()
                        self.resumeReady(.failure(Failure.cancelled))
                        self.finish(Failure.cancelled)
                    case .waiting(let error):
                        // A refused connection arrives as `.waiting`, not `.failed`, because
                        // Network.framework would otherwise retry forever. For a user who just
                        // tapped a Mac in a list, retrying forever is a hang.
                        let failure = Failure.transport(error.localizedDescription)
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

    /// Disarms the connect deadline. Takes the task under the lock and clears the slot, so a
    /// deadline can never be cancelled twice or left behind for the next connect attempt.
    private func cancelTimeout() {
        let handle = lock.withLock { () -> Task<Void, Never>? in
            let task = timeoutTask
            timeoutTask = nil
            return task
        }
        handle?.cancel()
    }

    // MARK: - Send

    /// Sends one frame. Ordering is the transport's, and it is preserved: Network.framework
    /// queues sends on the connection and writes them in the order they were handed over.
    public func send(_ frame: Frame) {
        guard let connection else { return }
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    /// Encodes and sends a command on the control channel. A failure to encode is a
    /// programming error, not a network condition, so it is logged rather than thrown —
    /// there is no useful recovery a caller could perform mid-gesture.
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
                    // A framing error is unrecoverable — the byte stream is unusable — so the
                    // connection is torn down rather than resynchronised onto a guess.
                    let failure = Failure.transport("\(error)")
                    connection?.cancel()
                    finish(failure)
                    return
                }
                let handler = lock.withLock { _onFrame }
                for frame in frames { handler?(frame) }
            }

            if let error {
                finish(.transport(error.localizedDescription))
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

    /// Ends the connection with `failure`, once. The first reason wins: the host's
    /// explanation arrives before its close, and overwriting it with "connection reset"
    /// would throw away the only message that tells the user what actually went wrong.
    private func finish(_ failure: Failure) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        closedReason = failure
        let pending = readyContinuation
        readyContinuation = nil
        let handler = _onClose
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
/// The rules come straight from ``RemoteCommand/coalescing``, and the distinction between
/// them is the whole point:
///
/// - **Absolute positions** (`.mouseMove`) are superseded by a newer sample, so the pending
///   one is replaced in place. Keeping its original *position* in the queue is what stops a
///   coalesced move from jumping ahead of a command that was queued before it.
/// - **Relative deltas** (`.joystickMove`, `.scroll`) are *summed*, never dropped. Replacing
///   them would silently discard the earlier part of a gesture, so a fast flick would arrive
///   as a single small nudge.
/// - **Everything else** is neither merged nor delayed. A dropped `mouseUp` leaves a button
///   stuck down on the Mac, so press/release pairs go out the moment they are produced,
///   after whatever was already pending.
///
/// The output rate is bounded by `interval` (60 Hz by default), with one exception: a command
/// that arrives when nothing has been sent for a full interval goes out immediately. Without
/// that leading edge, a single tap would wait up to 16 ms before its cursor move left, which
/// is precisely the latency the user feels.
public final class CommandCoalescer: @unchecked Sendable {
    /// The floor between two sends of *coalescable* commands, in seconds.
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

    /// Starts the trailing-edge timer. Idempotent, so it can be called on every reconnect.
    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
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

    public func enqueue(_ command: RemoteCommand) {
        lock.lock()
        insert(command)
        // The leading edge: send now if enough time has passed, or if this command may not
        // be merged or delayed at all. Otherwise the timer will pick it up.
        let due = command.coalescing == .none || now() - lastFlush >= interval
        let batch = due ? drain() : []
        lock.unlock()

        for item in batch { sink(item) }
    }

    /// Sends whatever is pending. Called by the timer, and by a caller that needs the queue
    /// drained before some out-of-band action.
    public func flush() {
        lock.lock()
        let batch = drain()
        lock.unlock()
        for item in batch { sink(item) }
    }

    // MARK: - Queue handling (call with `lock` held)

    private func insert(_ command: RemoteCommand) {
        switch command.coalescing {
        case .none:
            pending.append(command)

        case .replaceLatest:
            // Replaced *in place*. Appending instead would reorder the move ahead of
            // commands queued before it, which for a move-then-click pair means clicking at
            // the previous position.
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

    /// Whether two commands occupy the same slot in the queue and may be merged.
    ///
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
