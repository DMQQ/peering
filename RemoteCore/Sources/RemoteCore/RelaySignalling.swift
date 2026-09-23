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
    /// `entitlement` is what this device has bought and what it can prove: the relay takes the
    /// allowance from a verifying receipt, or from the claimed plan when there is none, so an empty
    /// entitlement is the free allowance.
    ///
    /// `clientProof` is this device signing for the ID it is announcing, which is what the relay
    /// meters relay time against when present: the announced ID starts over on a reinstall and the
    /// key it was signed with does not. See
    /// ``RelayDeviceProof/makeClientProof(clientID:identity:now:)``.
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
                case .pong, .registered: continue
                // Never sent unsolicited, and never in answer to a session request. Ignored rather
                // than refused: this conversation ends the moment `sessionReady` arrives, so a
                // message with more to say than this client asked for is no reason to lose it.
                case .peerAddress, .hostPresence: continue
                }
            }
        } onCancel: {
            // `URLSessionWebSocketTask.receive()` waits on Foundation rather than on a Swift
            // suspension point that cancellation resumes, so the socket is closed explicitly to
            // wake that receive and run the defer above.
            connection.cancel()
        }
    }

    /// Asks the relay which of these Macs are registered right now.
    ///
    /// One connection for the whole list, since this is a poll. Answers are matched by the `hostId`
    /// the relay echoes, not by the order they arrive in.
    ///
    /// A Mac that was asked about and never answered is absent from the result, which is the third
    /// state and the reason this returns a dictionary rather than a set. Nothing is thrown when the
    /// relay cannot be reached at all, since a phone that is offline has learned nothing.
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

                // Bounded by the questions asked plus room for the `pong` or `registered` that can
                // arrive alongside them, so a relay answering with something unexpected cannot spin
                // here. An older relay does not know the message and answers with an error, which
                // leaves the whole list unknown.
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

    /// Asks the relay where the other end of this session is, until it answers or gives up.
    ///
    /// Being told the peer has not been heard from yet is an ordinary answer rather than a failure:
    /// the first ask usually gets it, because the peer's bind datagram is still in flight. So this
    /// asks again, and `nil` means only that the asking ran out, which both callers treat as "stay
    /// on the relay".
    ///
    /// One connection for the whole conversation rather than one per ask.
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
                // Read before sleeping, so the first answer, which is often already waiting, is
                // returned without a delay that exists only to space out retries.
                switch try await connection.receive() {
                case .peerAddress(let address): return address
                case .error(let code, _) where code == "peerAddressUnknown":
                    guard attempt < attempts - 1 else { return nil }
                    try await Task.sleep(for: interval)
                case .error(let code, let message):
                    throw RelaySignallingError.refused(code: code, message: message)
                case .pong, .registered: continue
                // A presence answer this conversation did not ask for. Ignored: a relay with more
                // to say than this client asked is no reason to give up on the direct path.
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
