import Foundation
import Network
import Testing
@testable import RemoteCore

struct LANProbeTests {
    private func listener() throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        return listener
    }

    private func port(of listener: NWListener) async -> NWEndpoint.Port {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { @Sendable state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                continuation.resume()
            }
            listener.start(queue: .global())
        }
        return listener.port ?? 0
    }

    @Test func aListeningEndpointIsReachable() async throws {
        let listener = try listener()
        let port = await port(of: listener)
        defer { listener.cancel() }
        let reachable = await LANProbe.isReachable(.hostPort(host: "127.0.0.1", port: port))
        #expect(reachable)
    }

    @Test func aRefusedConnectionIsNotReachable() async {
        // Port 1 is reserved and nothing listens there, so the connect is refused at once.
        let reachable = await LANProbe.isReachable(.hostPort(host: "127.0.0.1", port: 1), timeout: 1)
        #expect(!reachable)
    }
}
