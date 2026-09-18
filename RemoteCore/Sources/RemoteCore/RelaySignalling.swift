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
    ///
    /// `entitlement` is what this device has bought and what it can prove — see ``RelayEntitlement``.
    /// The relay decides the allowance from the receipt when there is one that verifies and from
    /// the claimed plan when there is not, so an empty entitlement is the free allowance.
    public static func requestSession(
        at url: URL,
        hostID: String,
        clientID: String,
        entitlement: RelayEntitlement = RelayEntitlement()
    ) async throws -> RelaySession {
        let connection = RelaySignallingConnection(url: url)
        defer { connection.cancel() }
        try await connection.send(.connectToHost(
            hostID: hostID,
            clientID: clientID,
            protocolVersion: ProtocolInfo.version,
            apiKey: entitlement.apiKey,
            plan: entitlement.plan,
            jwsRepresentation: entitlement.jwsRepresentation
        ))

        while true {
            switch try await connection.receive() {
            case .sessionReady(let session): return session
            case .hostOffline(let id): throw RelaySignallingError.hostOffline(id)
            case .error(let code, let message): throw RelaySignallingError.refused(code: code, message: message)
            case .pong, .registered: continue
            // Never sent unsolicited, and never in answer to a session request. Ignored rather
            // than refused: this conversation is over the moment `sessionReady` arrives, and a
            // message from a relay with more to say than this client asked for is not a reason to
            // lose the session it has just handed over.
            case .peerAddress: continue
            }
        }
    }

    /// Asks the relay where the other end of this session is, until it answers or gives up.
    ///
    /// **Two ordinary answers, not one.** The first is an address. The second is being told that the
    /// peer has not been heard from yet — which is what the very first ask usually gets, because a
    /// client asks as soon as it has a session and the peer's own bind datagram is still in flight.
    /// So this asks again rather than reporting failure, and `nil` means only that the asking ran
    /// out, which is a state both callers treat as "stay on the relay".
    ///
    /// One connection for the whole conversation rather than one per ask: the asks are a few hundred
    /// milliseconds apart, and a TCP and TLS and WebSocket handshake each time would cost more than
    /// the asking does. The connection is still short-lived — it exists for this and no longer.
    public static func discoverPeer(
        at url: URL,
        videoToken: Data,
        attempts: Int = 8,
        interval: Duration = .milliseconds(150)
    ) async throws -> RelayPeerAddress? {
        let connection = RelaySignallingConnection(url: url)
        defer { connection.cancel() }
        try await connection.send(.requestPeerAddress(videoToken: videoToken))

        for attempt in 0..<max(1, attempts) {
            // Read before sleeping, so the first answer — which is often already waiting — is
            // returned without a delay that exists only to space out the retries.
            switch try await connection.receive() {
            case .peerAddress(let address): return address
            case .error(let code, _) where code == "peerAddressUnknown":
                guard attempt < attempts - 1 else { return nil }
                try await Task.sleep(for: interval)
            case .error(let code, let message):
                throw RelaySignallingError.refused(code: code, message: message)
            case .pong, .registered: continue
            case .sessionReady, .hostOffline:
                throw RelaySignallingError.unexpectedResponse
            }
        }
        return nil
    }
}
