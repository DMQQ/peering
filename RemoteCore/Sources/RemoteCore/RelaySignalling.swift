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

/// One JSON-over-WebSocket signalling connection to `peeringd`.
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

    /// Opens the short-lived phone-side signalling conversation and returns the allocated session.
    public static func requestSession(
        at url: URL,
        hostID: String,
        clientID: String,
        apiKey: String? = nil
    ) async throws -> RelaySession {
        let connection = RelaySignallingConnection(url: url)
        defer { connection.cancel() }
        try await connection.send(.connectToHost(
            hostID: hostID,
            clientID: clientID,
            protocolVersion: ProtocolInfo.version,
            apiKey: apiKey
        ))

        while true {
            switch try await connection.receive() {
            case .sessionReady(let session): return session
            case .hostOffline(let id): throw RelaySignallingError.hostOffline(id)
            case .error(let code, let message): throw RelaySignallingError.refused(code: code, message: message)
            case .pong, .registered: continue
            }
        }
    }
}
