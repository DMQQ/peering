import Foundation

/// What this device tells the relay about what it has bought, and what it can prove.
///
/// The three fields are the three things the relay can read, and they are worth different amounts.
/// `jwsRepresentation` is the proof: the signed transaction StoreKit handed back for the live
/// subscription, read off the `VerificationResult<Transaction>` that `Transaction.currentEntitlements`
/// yields rather than off the transaction it wraps. The relay verifies it against Apple's root and,
/// when it verifies, believes it over everything else here. `plan` is the claim, used when there is
/// no proof to check — an older app, or this one in the moment before `currentEntitlements`
/// answers. `apiKey` is neither: it is the only grant the relay holds on its own side, and this
/// app's key matches nothing in that list.
///
/// Grouped rather than passed as three arguments because the three travel together and are read
/// together, and because a call site that forgets one of them is a paying subscriber metered at
/// half an hour a day — the failure the proof exists to remove.
public struct RelayEntitlement: Sendable, Equatable {
    /// The plan this device is on: `free`, `relay`, `plus` or `pro`. Omitted means the free plan,
    /// which is also what an unrecognised spelling means.
    public let plan: String?
    /// The signed transaction for the subscription above, or `nil` when there is nothing to send.
    public let jwsRepresentation: String?
    public let apiKey: String?

    public init(
        plan: String? = nil,
        jwsRepresentation: String? = nil,
        apiKey: String? = nil
    ) {
        self.plan = plan
        self.jwsRepresentation = jwsRepresentation
        self.apiKey = apiKey
    }
}

/// Messages either app sends to `peeringd` over its signalling WebSocket.
public enum RelayClientMessage: Sendable, Equatable, Encodable {
    case registerHost(deviceID: String, name: String, protocolVersion: UInt16)
    /// A request for a session, with whatever this client can say about what it has bought.
    ///
    /// **`plan` is a claim and `jwsRepresentation` is the evidence for it.** The relay verifies the
    /// receipt against Apple's published root and meters by the product it names; the plan is read
    /// only when there is no receipt that verifies, which is the arrangement `storekit.rs` in the
    /// relay documents at length, including when it ends. Both are optional and both are read
    /// leniently: an unrecognised or absent plan, and any receipt that does not verify, mean the
    /// free allowance rather than a refusal to connect.
    case connectToHost(
        hostID: String,
        clientID: String,
        protocolVersion: UInt16,
        apiKey: String? = nil,
        plan: String? = nil,
        jwsRepresentation: String? = nil
    )
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, name, protocolVersion, apiKey, plan, jwsRepresentation
        case deviceID = "deviceId"
        case hostID = "hostId"
        case clientID = "clientId"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registerHost(let deviceID, let name, let protocolVersion):
            try container.encode("registerHost", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(name, forKey: .name)
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case .connectToHost(
            let hostID,
            let clientID,
            let protocolVersion,
            let apiKey,
            let plan,
            let jwsRepresentation
        ):
            try container.encode("connectToHost", forKey: .type)
            try container.encode(hostID, forKey: .hostID)
            try container.encode(clientID, forKey: .clientID)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            if let apiKey { try container.encode(apiKey, forKey: .apiKey) }
            // Left out rather than sent as null when there is nothing to say: the relay's own
            // spelling of "no plan" and "no receipt" is the field being absent, and both ends
            // agreeing on one spelling is one fewer case to get wrong.
            if let plan { try container.encode(plan, forKey: .plan) }
            // A few kilobytes of base64, which the signalling socket's 64 KB message limit has
            // room for — see the relay's `MAX_JWS_BYTES`, which is what refuses an oversized one.
            if let jwsRepresentation {
                try container.encode(jwsRepresentation, forKey: .jwsRepresentation)
            }
        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }
}

/// Everything both apps need after `peeringd` introduces them.
public struct RelaySession: Sendable, Equatable {
    public let controlHost: String
    public let controlPort: UInt16
    public let videoHost: String
    public let videoPort: UInt16
    public let controlToken: Data
    public let videoToken: Data

    public init(
        controlHost: String,
        controlPort: UInt16,
        videoHost: String,
        videoPort: UInt16,
        controlToken: Data,
        videoToken: Data
    ) {
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.videoHost = videoHost
        self.videoPort = videoPort
        self.controlToken = controlToken
        self.videoToken = videoToken
    }
}

public enum RelayProtocolError: LocalizedError, Sendable, Equatable {
    case unknownMessage(String)
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .unknownMessage(let type): return "The relay sent an unknown message type: \(type)."
        case .invalidToken: return "The relay sent an invalid session token."
        }
    }
}

/// Messages received from `peeringd` over the signalling WebSocket.
public enum RelayServerMessage: Sendable, Equatable, Decodable {
    case registered(sessionTTLSeconds: UInt64)
    case sessionReady(RelaySession)
    case hostOffline(deviceID: String)
    case pong
    case error(code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, controlHost, controlPort, videoHost, videoPort
        case sessionTTLSeconds = "sessionTtlSeconds"
        case controlToken, videoToken
        case deviceID = "deviceId"
        case code, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "registered":
            self = .registered(sessionTTLSeconds: try container.decode(UInt64.self, forKey: .sessionTTLSeconds))
        case "sessionReady":
            guard let controlToken = Self.token(
                try container.decode(String.self, forKey: .controlToken)
            ), let videoToken = Self.token(
                try container.decode(String.self, forKey: .videoToken)
            ) else {
                throw RelayProtocolError.invalidToken
            }
            self = .sessionReady(RelaySession(
                controlHost: try container.decode(String.self, forKey: .controlHost),
                controlPort: try container.decode(UInt16.self, forKey: .controlPort),
                videoHost: try container.decode(String.self, forKey: .videoHost),
                videoPort: try container.decode(UInt16.self, forKey: .videoPort),
                controlToken: controlToken,
                videoToken: videoToken
            ))
        case "hostOffline":
            self = .hostOffline(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "pong":
            self = .pong
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            throw RelayProtocolError.unknownMessage(type)
        }
    }

    private static func token(_ hex: String) -> Data? {
        guard hex.utf8.count == 32 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        for _ in 0..<16 {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }
}

/// The JSON codec for the relay's public WebSocket contract.
public enum RelayMessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
