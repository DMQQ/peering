import Foundation
import os
import RemoteCore

private let relayLog = Logger(subsystem: "pl.dmq.peering.host", category: "relay")

final class RelayHostRegistration: @unchecked Sendable {
    private let device: DeviceIdentity
    private let identity: SelfSignedIdentity
    private let onSession: @Sendable (RelaySession) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RelaySignallingConnection?

    private struct PendingNotification: Sendable {
        let token: String
        let title: String
        let body: String
        let source: String?
        let action: RelayPushAction?
    }

    /// How many notifications may wait for the relay.
    private static let maximumPending = 16

    private var pending: [PendingNotification] = []

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
        lock.unlock()
    }

    func notifyDevice(token: String, title: String, body: String, source: String? = nil, action: RelayPushAction? = nil) {
        var overflowed = 0
        var heldForRelay = false

        let batch = lock.withLock { () -> (RelaySignallingConnection, [PendingNotification])? in
            pending.append(PendingNotification(token: token, title: title, body: body, source: source, action: action))
            if pending.count > Self.maximumPending {
                overflowed = pending.count - Self.maximumPending
                pending.removeFirst(overflowed)
            }
            guard let connection else {
                heldForRelay = true
                return nil
            }
            let items = pending
            pending.removeAll(keepingCapacity: true)
            return (connection, items)
        }

        // Logged outside the lock, because `os_log` is not a thing to do while holding one.
        if overflowed > 0 {
            relayLog.notice("\(overflowed, privacy: .public) notification(s) dropped: the relay has been unreachable for longer than this queue covers")
        }
        if heldForRelay {
            relayLog.notice("holding \(self.pendingCount(), privacy: .public) notification(s) until this Mac is registered with the relay")
        }
        guard let batch else { return }
        send(batch.1, over: batch.0)
    }

    /// Sends a batch in order, and puts back whatever the relay did not take.
    private func send(_ items: [PendingNotification], over connection: RelaySignallingConnection) {
        guard !items.isEmpty else { return }
        Task.detached { [weak self] in
            for (index, item) in items.enumerated() {
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
        let items = lock.withLock { () -> [PendingNotification] in
            let items = pending
            pending.removeAll(keepingCapacity: true)
            return items
        }
        send(items, over: connection)
    }

    private func requeue(_ items: [PendingNotification]) {
        guard !items.isEmpty else { return }
        lock.withLock { pending.insert(contentsOf: items, at: 0) }
    }

    private func pendingCount() -> Int {
        lock.withLock { pending.count }
    }

    func stop() {
        let values = lock.withLock { () -> (Task<Void, Never>?, RelaySignallingConnection?) in
            let values = (task, connection)
            task = nil
            connection = nil
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
    }

    private func run() async {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
        var attempt = 0

        while !Task.isCancelled {
            onStatus("Connecting to getpeering.app…")
            let connection = RelaySignallingConnection(url: ProtocolInfo.relaySignallingURL)
            lock.withLock { self.connection = connection }
            do {
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

                var registered = false
                let pinger = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(25))
                        guard !Task.isCancelled else { return }
                        try? await connection.send(.ping)
                    }
                }
                defer { pinger.cancel() }

                while !Task.isCancelled {
                    switch try await connection.receive() {
                    case .registered:
                        if !registered {
                            registered = true
                            attempt = 0
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
                    // Never sent unsolicited, and never in answer to anything this end says: the
                    // Mac learns where its clients are by being sent to. Ignored rather than
                    // refused, because a relay that says more than this build expects is no reason
                    // to drop a working registration.
                    case .peerAddress, .hostPresence, .referral:
                        break
                    }
                }
            } catch {
                Analytics.failed(error, in: .relay)
                HostTelemetry.relay(error)
                connection.cancel()
                guard !Task.isCancelled else { break }
                onStatus("Relay unavailable: \(error.localizedDescription)")
            }

            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }
}
