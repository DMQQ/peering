import Foundation
import RemoteCore

/// Keeps this Mac present at the public relay and accepts session allocations pushed by it.
final class RelayHostRegistration: @unchecked Sendable {
    private let device: DeviceIdentity
    private let onSession: @Sendable (RelaySession) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RelaySignallingConnection?

    init(
        device: DeviceIdentity,
        onSession: @escaping @Sendable (RelaySession) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.device = device
        self.onSession = onSession
        self.onStatus = onStatus
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        // Detached deliberately: `start()` is called by the main-actor UI model, but a permanent
        // WebSocket receive loop is networking work and must not inherit that actor's executor.
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.run()
        }
        self.task = task
        lock.unlock()
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
            onStatus("Connecting to peering.dmqq.dev…")
            let connection = RelaySignallingConnection(url: ProtocolInfo.relaySignallingURL)
            lock.withLock { self.connection = connection }
            do {
                try await connection.send(.registerHost(
                    deviceID: device.id,
                    name: device.name,
                    protocolVersion: ProtocolInfo.version
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
                            onStatus("Registered with peering.dmqq.dev")
                        }
                    case .sessionReady(let session):
                        onSession(session)
                    case .pong:
                        break
                    case .error(_, let message):
                        throw RelaySignallingError.refused(code: "relay", message: message)
                    case .hostOffline:
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
