import Foundation
import os
import RemoteCore

private let relayLog = Logger(subsystem: "pl.dmq.peering.host", category: "relay")

/// Keeps this Mac present at the public relay and accepts session allocations pushed by it.
final class RelayHostRegistration: @unchecked Sendable {
    private let device: DeviceIdentity
    /// The key this Mac signs its registration with. See ``RelayDeviceProof``.
    private let identity: SelfSignedIdentity
    private let onSession: @Sendable (RelaySession) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RelaySignallingConnection?

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

    /// Asks the relay to push an APNs notification to the given device token. Fire-and-forget:
    /// a push sent while the signalling socket is down is lost, not queued.
    func notifyDevice(token: String, title: String, body: String) {
        let connection = lock.withLock { connection }
        guard let connection else { return }
        Task.detached {
            do {
                try await connection.send(.notifyDevice(token: token, title: title, body: body))
            } catch {
                relayLog.error("the relay did not take a notification for \(token, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
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
                //
                // A signature that fails is not fatal: the registration goes out without a proof,
                // which the relay still accepts for an id nobody has claimed.
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
                    case .peerAddress, .hostPresence:
                        break
                    }
                }
            } catch {
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
