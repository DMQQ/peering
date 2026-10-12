import Foundation

public struct RelayEntitlement: Sendable, Equatable {
    public let plan: String?
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
    /// `proof` is optional on the wire so a build that predates it keeps working.
    case registerHost(
        deviceID: String,
        name: String,
        protocolVersion: UInt16,
        proof: RelayDeviceProof? = nil
    )
    /// `plan` is a claim, `jwsRepresentation` the evidence; an unverifiable receipt means the free allowance, not a refusal.
    /// `clientProof`, when present, keys the allowance (the announced client ID resets on reinstall). Optional on the wire.
    case connectToHost(
        hostID: String,
        clientID: String,
        protocolVersion: UInt16,
        apiKey: String? = nil,
        plan: String? = nil,
        jwsRepresentation: String? = nil,
        clientProof: RelayDeviceProof? = nil
    )
    /// `peerAddressUnknown` is the ordinary first answer, not a failure.
    case requestPeerAddress(videoToken: Data)
    /// Asked only while the Connect tab is open, never in the background, so the relay cannot learn which Macs a phone wants.
    case hostPresence(hostID: String)
    case ping
    case referralStatus(clientID: String, proof: RelayDeviceProof)
    case redeemReferral(clientID: String, code: String, proof: RelayDeviceProof)
    /// Only a registered Mac may send this.
    /// `source` is the terminal window the notification is about; omitted when nil.
    /// `action` makes the notification answerable from the Lock Screen: the category names its buttons and the ids say what they answer.
    case notifyDevice(token: String, title: String, body: String, source: String? = nil, action: RelayPushAction? = nil)
    /// Only a registered Mac may send this. A push the relay does not send is answered with ``RelayServerMessage/activityRefused(_:)``.
    case notifyActivity(RelayActivityPush)

    private enum CodingKeys: String, CodingKey {
        case type, name, protocolVersion, apiKey, plan, jwsRepresentation
        case publicKey, proof, proofTime
        /// The APNs token, under its own key: `token` is the video token on the peer-address
        /// message, and the relay's `NotifyDevice` reads `device_token`.
        case deviceToken
        case deviceID = "deviceId"
        case hostID = "hostId"
        case clientID = "clientId"
        case videoToken
        case token, title, body, source, category
        case activityToken, activity, event, contentState, staleSeconds, priority
        case attributesType, attributes, alertTitle, alertBody, environment
        case code
        case sessionID = "sessionId"
        case approvalID = "approvalId"
    }


    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registerHost(let deviceID, let name, let protocolVersion, let proof):
            try container.encode("registerHost", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(name, forKey: .name)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(proof?.publicKey, forKey: .publicKey)
            try container.encodeIfPresent(proof?.signature, forKey: .proof)
            try container.encodeIfPresent(proof?.proofTime, forKey: .proofTime)
        case .connectToHost(
            let hostID,
            let clientID,
            let protocolVersion,
            let apiKey,
            let plan,
            let jwsRepresentation,
            let clientProof
        ):
            try container.encode("connectToHost", forKey: .type)
            try container.encode(hostID, forKey: .hostID)
            try container.encode(clientID, forKey: .clientID)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            if let apiKey { try container.encode(apiKey, forKey: .apiKey) }
            // Same field names as the host registration, signed over a different payload (told apart by version tag).
            if let clientProof {
                try container.encode(clientProof.publicKey, forKey: .publicKey)
                try container.encode(clientProof.signature, forKey: .proof)
                try container.encode(clientProof.proofTime, forKey: .proofTime)
            }
            if let plan { try container.encode(plan, forKey: .plan) }
            if let jwsRepresentation {
                try container.encode(jwsRepresentation, forKey: .jwsRepresentation)
            }
        case .hostPresence(let hostID):
            try container.encode("hostPresence", forKey: .type)
            try container.encode(hostID, forKey: .hostID)
        case .requestPeerAddress(let videoToken):
            try container.encode("requestPeerAddress", forKey: .type)
            try container.encode(Self.hex(videoToken), forKey: .videoToken)
        case .ping:
            try container.encode("ping", forKey: .type)
        case .referralStatus(let clientID, let proof):
            try container.encode("referralStatus", forKey: .type)
            try container.encode(clientID, forKey: .clientID)
            try Self.encode(proof, into: &container)
        case .redeemReferral(let clientID, let code, let proof):
            try container.encode("redeemReferral", forKey: .type)
            try container.encode(clientID, forKey: .clientID)
            try container.encode(code, forKey: .code)
            try Self.encode(proof, into: &container)
        case .notifyDevice(let token, let title, let body, let source, let action):
            try container.encode("notifyDevice", forKey: .type)
            try container.encode(token, forKey: .deviceToken)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
            try container.encodeIfPresent(source, forKey: .source)
            try container.encodeIfPresent(action?.category, forKey: .category)
            try container.encodeIfPresent(action?.sessionID, forKey: .sessionID)
            try container.encodeIfPresent(action?.approvalID, forKey: .approvalID)
        case .notifyActivity(let push):
            try container.encode("notifyActivity", forKey: .type)
            try container.encode(push.activityToken, forKey: .activityToken)
            try container.encode(push.activity, forKey: .activity)
            try container.encode(push.event, forKey: .event)
            try container.encode(push.contentState, forKey: .contentState)
            try container.encodeIfPresent(push.staleSeconds, forKey: .staleSeconds)
            try container.encodeIfPresent(push.priority, forKey: .priority)
            try container.encodeIfPresent(push.attributesType, forKey: .attributesType)
            try container.encodeIfPresent(push.attributes, forKey: .attributes)
            try container.encodeIfPresent(push.alertTitle, forKey: .alertTitle)
            try container.encodeIfPresent(push.alertBody, forKey: .alertBody)
            try container.encode(push.environment, forKey: .environment)
        }
    }

    private static func encode(_ proof: RelayDeviceProof, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(proof.publicKey, forKey: .publicKey)
        try container.encode(proof.signature, forKey: .proof)
        try container.encode(proof.proofTime, forKey: .proofTime)
    }

    /// `%02x` keeps leading zeros; the relay's `unhex` refuses a short token.
    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The part of a push that lets the phone answer an agent's approval request from the notification.
public struct RelayPushAction: Sendable, Equatable {
    public let category: String
    public let sessionID: String
    public let approvalID: String

    public init(category: String, sessionID: String, approvalID: String) {
        self.category = category
        self.sessionID = sessionID
        self.approvalID = approvalID
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
    /// Seconds left in the relay's current one-day window, referral bonus included. Absent from older relays and for unmetered plans.
    public let remainingSeconds: UInt64?

    public init(
        controlHost: String,
        controlPort: UInt16,
        videoHost: String,
        videoPort: UInt16,
        controlToken: Data,
        videoToken: Data,
        remainingSeconds: UInt64? = nil
    ) {
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.videoHost = videoHost
        self.videoPort = videoPort
        self.controlToken = controlToken
        self.videoToken = videoToken
        self.remainingSeconds = remainingSeconds
    }
}

public struct RelayPeerAddress: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
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
    case peerAddress(RelayPeerAddress)
    /// `online: false` is about registration with the relay, not the Mac's reachability.
    case hostPresence(deviceID: String, online: Bool)
    case pong
    case referral(RelayReferral)
    case error(code: String, message: String)
    /// Answers a `notifyActivity` that was not sent.
    case activityRefused(RelayActivityRefusal)

    private enum CodingKeys: String, CodingKey {
        case type, controlHost, controlPort, videoHost, videoPort
        case sessionTTLSeconds = "sessionTtlSeconds"
        case controlToken, videoToken, remainingSeconds
        case deviceID = "deviceId"
        case hostID = "hostId"
        case online
        case code, message, reason
        case host, port
        case bonusSeconds, bonusEndsAt, redeemed, invitesEarned, invitesMax
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
                videoToken: videoToken,
                remainingSeconds: try container.decodeIfPresent(UInt64.self, forKey: .remainingSeconds)
            ))
        case "hostOffline":
            self = .hostOffline(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "peerAddress":
            self = .peerAddress(RelayPeerAddress(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(UInt16.self, forKey: .port)
            ))
        case "hostPresence":
            self = .hostPresence(
                deviceID: try container.decode(String.self, forKey: .hostID),
                online: try container.decode(Bool.self, forKey: .online)
            )
        case "pong":
            self = .pong
        case "referral":
            self = .referral(RelayReferral(
                code: try container.decode(String.self, forKey: .code),
                bonusSeconds: try container.decode(TimeInterval.self, forKey: .bonusSeconds),
                bonusEndsAt: try container.decodeIfPresent(TimeInterval.self, forKey: .bonusEndsAt)
                    .map(Date.init(timeIntervalSince1970:)),
                redeemed: try container.decode(Bool.self, forKey: .redeemed),
                invitesEarned: try container.decode(Int.self, forKey: .invitesEarned),
                invitesMax: try container.decode(Int.self, forKey: .invitesMax)
            ))
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "activityRefused":
            self = .activityRefused(try container.decode(RelayActivityRefusal.self, forKey: .reason))
        default:
            throw RelayProtocolError.unknownMessage(type)
        }
    }

    /// Sixteen bytes, spelled as thirty-two hex digits. Both guards are load-bearing.
    ///
    /// The count is in characters, the unit the loop moves in: a string of thirty-two bytes can be
    /// fewer than thirty-two characters, and walking sixteen times then reads past the end and takes
    /// the process down. Every character must also be an ASCII hex digit, because
    /// `UInt8(_:radix:)` accepts a leading `+`, so sixteen `+1`s would decode to one-bytes.
    private static func token(_ hex: String) -> Data? {
        guard hex.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
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
