import Foundation

/// How long each step after the socket is up may take. Only the TLS dial had a limit, so a relay or Mac that stalled afterwards left the phone on "Connecting" for good.
public enum ConnectDeadlines {
    public static let relayRequest: TimeInterval = 15
    public static let handshake: TimeInterval = 15
    public static let peerDiscovery: TimeInterval = 5
}

public enum Deadline {
    public struct Exceeded: Error, Equatable, Sendable {}

    /// Races `operation` against a timer; the loser is cancelled. `sleep` is a parameter so a test decides which one wins without waiting.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleep(seconds)
                throw Exceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Exceeded() }
            return first
        }
    }
}
