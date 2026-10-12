import Foundation

public enum RelaySignallingError: LocalizedError, Sendable, Equatable {
    case nonWebSocketResponse
    case hostOffline(String)
    case refused(code: String, message: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .nonWebSocketResponse: return "The relay sent a response that was not a WebSocket message."
        case .hostOffline: return "That Mac is not currently registered with the relay."
        case .refused(_, let message): return "The relay refused the session: \(message)"
        case .unexpectedResponse: return "The relay answered in an unexpected order."
        }
    }
}

public final class RelaySignallingConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    public func send(_ message: RelayClientMessage) async throws {
        try await task.send(try Self.wireMessage(message))
    }

    static func wireMessage(_ message: RelayClientMessage) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try RelayMessageCodec.encode(message), as: UTF8.self))
    }

    public func receive() async throws -> RelayServerMessage {
        let data: Data
        switch try await task.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw RelaySignallingError.nonWebSocketResponse
        }
        return try RelayMessageCodec.decode(RelayServerMessage.self, from: data)
    }

    public func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }

    public static func requestSession(
        at url: URL,
        hostID: String,
        clientID: String,
        entitlement: RelayEntitlement = RelayEntitlement(),
        clientProof: RelayDeviceProof? = nil
    ) async throws -> RelaySession {
        let connection = RelaySignallingConnection(url: url)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await connection.send(.connectToHost(
                hostID: hostID,
                clientID: clientID,
                protocolVersion: ProtocolInfo.version,
                apiKey: entitlement.apiKey,
                plan: entitlement.plan,
                jwsRepresentation: entitlement.jwsRepresentation,
                clientProof: clientProof
            ))

            while true {
                try Task.checkCancellation()
                switch try await connection.receive() {
                case .sessionReady(let session): return session
                case .hostOffline(let id): throw RelaySignallingError.hostOffline(id)
                case .error(let code, let message): throw RelaySignallingError.refused(code: code, message: message)
                case .pong, .registered, .referral, .activityRefused: continue
                case .peerAddress, .hostPresence: continue
                }
            }
        } onCancel: {
            // `receive()` ignores cancellation, so the socket is closed explicitly to wake it.
            connection.cancel()
        }
    }

    /// A Mac that never answered is absent from the result (a dictionary, not a set, for that third state).
    /// - Returns: `(presence, reachable)` where `reachable` is `true` when at least one round-trip
    ///   completed, distinguishing "relay down" from "relay up but Mac not registered".
    public static func hostPresence(
        at url: URL,
        hostIDs: [String]
    ) async -> (presence: [String: Bool], reachable: Bool) {
        guard !hostIDs.isEmpty else { return ([:], true) }

        let connection = RelaySignallingConnection(url: url)
        return await withTaskCancellationHandler {
            defer { connection.cancel() }

            var presence: [String: Bool] = [:]
            var reachable = false
            do {
                for hostID in hostIDs {
                    try Task.checkCancellation()
                    try await connection.send(.hostPresence(hostID: hostID))
                }

                // Bounded so an unexpected relay reply cannot spin here; an older relay answers an error, leaving every Mac unknown.
                var outstanding = Set(hostIDs)
                for _ in 0..<(hostIDs.count * 2 + 4) where !outstanding.isEmpty {
                    try Task.checkCancellation()
                    let msg = try await connection.receive()
                    reachable = true
                    switch msg {
                    case .hostPresence(let id, let online):
                        presence[id] = online
                        outstanding.remove(id)
                    case .error:
                        return (presence, reachable)
                    default:
                        continue
                    }
                }
            } catch {
                return (presence, reachable)
            }
            return (presence, reachable)
        } onCancel: {
            connection.cancel()
        }
    }

    /// `nil` means only that the asking ran out. A peer not yet heard from is the ordinary first answer, so it asks again.
    public static func discoverPeer(
        at url: URL,
        videoToken: Data,
        attempts: Int = 8,
        interval: Duration = .milliseconds(150)
    ) async throws -> RelayPeerAddress? {
        let connection = RelaySignallingConnection(url: url)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await connection.send(.requestPeerAddress(videoToken: videoToken))

            for attempt in 0..<max(1, attempts) {
                try Task.checkCancellation()
                // Read before sleeping so an already-waiting answer is not delayed.
                switch try await connection.receive() {
                case .peerAddress(let address): return address
                case .error(let code, _) where code == "peerAddressUnknown":
                    guard attempt < attempts - 1 else { return nil }
                    try await Task.sleep(for: interval)
                case .error(let code, let message):
                    throw RelaySignallingError.refused(code: code, message: message)
                case .pong, .registered, .referral, .activityRefused: continue
                case .hostPresence: continue
                case .sessionReady, .hostOffline:
                    throw RelaySignallingError.unexpectedResponse
                }
            }
            return nil
        } onCancel: {
            connection.cancel()
        }
    }
}
