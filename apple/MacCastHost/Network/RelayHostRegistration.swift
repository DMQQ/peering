import Foundation
import MacCastKit
import os
import RemoteCore

private let relayLog = Logger(subsystem: "pl.dmq.peering.host", category: "relay")

final class RelayHostRegistration: @unchecked Sendable {
    private let device: DeviceIdentity
    private let identity: SelfSignedIdentity
    private let onSession: @Sendable (RelaySession) -> Void
    private let onStatus: @Sendable (String) -> Void
    /// Called when the relay answers a Live Activity push with a refusal.
    var onActivityRefused: (@Sendable (RelayActivityRefusal, String?) -> Void)?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RelaySignallingConnection?
    private var networkObserver: NetworkChangeObserver?
    private var reconnectRequested = false

    private struct PendingNotification: Sendable {
        let token: String
        let title: String
        let body: String
        let source: String?
        let action: RelayPushAction?
    }

    private var pending = NotificationHoldQueue<PendingNotification>()

    init(
        device: DeviceIdentity,
        identity: SelfSignedIdentity,
        onSession: @escaping @Sendable (RelaySession) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.device = device
        self.identity = identity
        self.onSession = onSession
        self.onStatus = onStatus
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        // Detached deliberately: `start()` is called by the main-actor UI model, but a permanent
        // WebSocket receive loop must not inherit that actor's executor.
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.run()
        }
        self.task = task
        networkObserver = NetworkChangeObserver { [weak self] in self?.registerAgain() }
        lock.unlock()
    }

    func notifyDevice(token: String, title: String, body: String, source: String? = nil, action: RelayPushAction? = nil) {
        let item = PendingNotification(token: token, title: title, body: body, source: source, action: action)
        let outcome = lock.withLock { () -> (dropped: Int?, batch: (RelaySignallingConnection, [NotificationHoldQueue<PendingNotification>.Entry])?) in
            let now = Date()
            let dropped = pending.add(item, token: token, source: source, answerable: action != nil, now: now)
            guard dropped != nil, let connection else { return (dropped, nil) }
            return (dropped, (connection, pending.drain(now: now)))
        }

        // Logged outside the lock, because `os_log` is not a thing to do while holding one.
        if let dropped = outcome.dropped, dropped > 0 {
            relayLog.notice("\(dropped, privacy: .public) notification(s) dropped: expired, or more were waiting than the queue covers")
        }
        guard let batch = outcome.batch else {
            if outcome.dropped != nil { relayLog.notice("holding a notification until this Mac is registered with the relay") }
            return
        }
        send(batch.1, over: batch.0)
    }

    /// A Live Activity update is perishable, so unlike a notification it is not held for a relay that is away: the planner sends the latest state again at the next change.
    func notifyActivity(_ push: RelayActivityPush, completion: (@Sendable () -> Void)? = nil) {
        guard let connection = lock.withLock({ self.connection }) else {
            relayLog.notice("a Live Activity update was not sent: this Mac is not registered with the relay")
            completion?()
            return
        }
        Task.detached {
            defer { completion?() }
            do {
                try await connection.send(.notifyActivity(push))
            } catch {
                Analytics.failed(error, in: .relay)
                relayLog.error("the relay did not take a Live Activity update: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// For a device that was unpaired: nothing held for it should reach it later.
    func dropPending(token: String) {
        lock.withLock { pending.forget(token: token) }
    }

    func dropAllPending() {
        lock.withLock { pending.forgetAll() }
    }

    /// Sends a batch in order, and puts back whatever the relay did not take.
    private func send(_ items: [NotificationHoldQueue<PendingNotification>.Entry], over connection: RelaySignallingConnection) {
        guard !items.isEmpty else { return }
        Task.detached { [weak self] in
            for (index, entry) in items.enumerated() {
                let item = entry.item
                do {
                    try await connection.send(.notifyDevice(
                        token: item.token,
                        title: item.title,
                        body: item.body,
                        source: item.source,
                        action: item.action
                    ))
                } catch {
                    Analytics.failed(error, in: .relay)
                    relayLog.error("the relay did not take a notification for \(item.token, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // Back to the front, in order, so the next registration sends these before
                    // anything that was queued behind them.
                    self?.requeue(Array(items[index...]))
                    return
                }
            }
        }
    }

    private func flush(over connection: RelaySignallingConnection) {
        let items = lock.withLock { pending.drain(now: Date()) }
        send(items, over: connection)
    }

    private func requeue(_ items: [NotificationHoldQueue<PendingNotification>.Entry]) {
        guard !items.isEmpty else { return }
        lock.withLock { pending.requeue(items) }
    }

    func stop() {
        let values = lock.withLock { () -> (Task<Void, Never>?, RelaySignallingConnection?, NetworkChangeObserver?) in
            let values = (task, connection, networkObserver)
            task = nil
            connection = nil
            networkObserver = nil
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2?.cancel()
    }

    /// After a wake or a network change the old socket may look open and carry nothing, so it is dropped and registered anew without waiting out a back-off.
    private func registerAgain() {
        let current = lock.withLock { () -> RelaySignallingConnection? in
            reconnectRequested = true
            return connection
        }
        relayLog.notice("the network changed or the Mac woke; registering with the relay again")
        current?.cancel()
    }

    private func takeReconnectRequest() -> Bool {
        lock.withLock {
            defer { reconnectRequested = false }
            return reconnectRequested
        }
    }

    private func run() async {
        var policy = ReconnectPolicy()

        while !Task.isCancelled {
            _ = takeReconnectRequest()
            onStatus("Connecting to getpeering.app…")
            let connection = RelaySignallingConnection(url: ProtocolInfo.relaySignallingURL)
            lock.withLock { self.connection = connection }
            do {
                try await register(over: connection, policy: &policy)
            } catch {
                Analytics.failed(error, in: .relay)
                HostTelemetry.relay(error)
                connection.cancel()
                guard !Task.isCancelled else { break }
                onStatus("Relay unavailable: \(error.localizedDescription)")
            }

            if takeReconnectRequest() {
                _ = policy.delayAfterEnd(at: Date(), jitter: 0)
                continue
            }
            let delay = policy.delayAfterEnd(at: Date(), jitter: Double.random(in: 0...1))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Registers and then serves the socket until it fails. Returns only by throwing.
    private func register(over connection: RelaySignallingConnection, policy: inout ReconnectPolicy) async throws {
        // Signed per attempt, not once: the proof carries a timestamp the relay only
        // accepts for a few minutes either side of its own clock, and this loop retries
        // for as long as the Mac runs, so a single proof would be stale by the second
        // attempt and the Mac would never register again after a network blip.
        let proof = try? RelayDeviceProof.make(deviceID: device.id, identity: identity)
        if proof == nil {
            onStatus("This Mac could not sign its registration; the relay may refuse it.")
        }

        try await connection.send(.registerHost(
            deviceID: device.id,
            name: device.name,
            protocolVersion: ProtocolInfo.version,
            proof: proof
        ))

        let watchdog = SignallingWatchdog()
        let pinger = Task { [onStatus] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                if watchdog.pingDue() {
                    onStatus("The relay stopped answering; registering again")
                    connection.cancel()
                    return
                }
                try? await connection.send(.ping)
            }
        }
        defer { pinger.cancel() }

        var registered = false
        while !Task.isCancelled {
            let message = try await connection.receive()
            watchdog.heard()
            switch message {
            case .registered:
                if !registered {
                    registered = true
                    policy.registered(at: Date())
                    onStatus("Registered with getpeering.app")
                    // Anything held while there was no relay goes now, in the order it was
                    // raised. See ``notifyDevice(token:title:body:)``.
                    flush(over: connection)
                }
            case .sessionReady(let session):
                onSession(session)
            case .pong:
                break
            case .error(_, let message):
                throw RelaySignallingError.refused(code: "relay", message: message)
            case .hostOffline:
                break
            case .activityRefused(let reason, let requestId):
                onActivityRefused?(reason, requestId)
            // Never sent unsolicited, and never in answer to anything this end says: the
            // Mac learns where its clients are by being sent to. Ignored rather than
            // refused, because a relay that says more than this build expects is no reason
            // to drop a working registration.
            case .peerAddress, .hostPresence, .referral:
                break
            }
        }
    }
}

private final class SignallingWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var liveness = SignallingLiveness()

    func heard() { lock.withLock { liveness.heard() } }
    func pingDue() -> Bool { lock.withLock { liveness.pingDue() } }
}
