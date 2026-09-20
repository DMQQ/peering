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
    /// A Mac announcing itself, with the proof that it is the Mac it says it is.
    ///
    /// **`proof` is optional on the wire and the relay accepts its absence**, which is what lets a
    /// build that predates this keep working. What the proof buys is that an ID which has been
    /// proved once can only be registered by the device that proved it. See ``RelayDeviceProof``
    /// for what is signed and why a signature rather than a shared secret.
    case registerHost(
        deviceID: String,
        name: String,
        protocolVersion: UInt16,
        proof: RelayDeviceProof? = nil
    )
    /// A request for a session, with whatever this client can say about what it has bought.
    ///
    /// **`plan` is a claim and `jwsRepresentation` is the evidence for it.** The relay verifies the
    /// receipt against Apple's published root and meters by the product it names; the plan is read
    /// only when there is no receipt that verifies, which is the arrangement `storekit.rs` in the
    /// relay documents at length, including when it ends. Both are optional and both are read
    /// leniently: an unrecognised or absent plan, and any receipt that does not verify, mean the
    /// free allowance rather than a refusal to connect.
    /// **`clientProof` is what the allowance is keyed on when it is present.** Without it the relay
    /// meters the announced client ID, which is a string in the app's own storage and starts over
    /// when the app is reinstalled. With it the relay meters the key, which is in the Keychain and
    /// does not. Optional on the wire, so a build that predates this is metered the old way rather
    /// than refused. See ``RelayDeviceProof/makeClientProof(clientID:identity:now:)``.
    case connectToHost(
        hostID: String,
        clientID: String,
        protocolVersion: UInt16,
        apiKey: String? = nil,
        plan: String? = nil,
        jwsRepresentation: String? = nil,
        clientProof: RelayDeviceProof? = nil
    )
    /// Ask the relay where the other end of this session is.
    ///
    /// Asked with this end's own video token, which is the only thing either end holds that says
    /// which of the session's two slots it is — so the answer is always the *peer*. Nothing new is
    /// collected to answer it either: the relay already stores each slot's observed address, because
    /// forwarding is impossible without it.
    ///
    /// Expect to be told `peerAddressUnknown` on the first ask. A client asks as soon as it has a
    /// session and before it has sent a datagram, so the peer has usually not been heard from yet;
    /// that is the ordinary first answer, not a failure, and the caller asks again.
    case requestPeerAddress(videoToken: Data)
    /// Is this Mac registered with the relay right now?
    ///
    /// **Asked because Bonjour cannot answer it and the app was drawing that silence as absence.**
    /// The green dot on a paired Mac came from the local browse, so a Mac reached through the relay
    /// was drawn as though it were switched off. The relay knows the answer and already gives it
    /// away in `hostOffline` to anyone who tries to connect; this is the same fact asked as a
    /// question, so asking does not cost a session.
    ///
    /// What it costs is a disclosure worth naming: a phone that asks after three Macs has told the
    /// relay which three it is interested in, where before it revealed one at the moment it
    /// connected to it. It is asked while the Connect tab is open and never in the background.
    case hostPresence(hostID: String)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, name, protocolVersion, apiKey, plan, jwsRepresentation
        // Both messages carry a proof under these three names. They are over different strings,
        // which the relay tells apart by the payload's version tag rather than by the field name.
        case publicKey, proof, proofTime
        case deviceID = "deviceId"
        case hostID = "hostId"
        case clientID = "clientId"
        case videoToken
    }


    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registerHost(let deviceID, let name, let protocolVersion, let proof):
            try container.encode("registerHost", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(name, forKey: .name)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            // All three or none. The relay treats a partial proof as a message it does not
            // understand rather than salvaging what is there, so sending two of them would be
            // sending something that gets refused for looking broken.
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
            // Three fields or none, the same shape and the same names the host registration uses.
            // What is signed is not the same, and the relay keeps the two payloads apart by their
            // version tag rather than by the field names: this one is over
            // ``RelayDeviceProof/clientPayload(clientID:proofTime:)``.
            if let clientProof {
                try container.encode(clientProof.publicKey, forKey: .publicKey)
                try container.encode(clientProof.signature, forKey: .proof)
                try container.encode(clientProof.proofTime, forKey: .proofTime)
            }
            // Left out rather than sent as null when there is nothing to say: the relay's own
            // spelling of "no plan" and "no receipt" is the field being absent, and both ends
            // agreeing on one spelling is one fewer case to get wrong.
            if let plan { try container.encode(plan, forKey: .plan) }
            // A few kilobytes of base64, which the signalling socket's 64 KB message limit has
            // room for — see the relay's `MAX_JWS_BYTES`, which is what refuses an oversized one.
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
        }
    }

    /// Lowercase hex of sixteen bytes, which is how the relay spells a video token on the wire.
    ///
    /// The relay's `unhex` is exact about length and forgiving about case, so the only way to get
    /// this wrong is to drop a leading zero — which is what `%02x` is here to prevent, and which
    /// would otherwise turn a token into a thirty-one character string the relay refuses.
    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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

/// Where the other end of a session was last seen, as seen from the relay's outside.
///
/// **An observation, not a promise.** It is the source address of the peer's most recent video
/// datagram, so it is the peer as the peer's own NAT presents it — which is exactly the address
/// anything else on the internet would have to send to. Whether the peer's NAT will *accept* a
/// packet from a third party is a different question that the relay cannot answer, and this type
/// carries no claim about it: the two ends settle that between themselves by trying, and by needing
/// nothing but the session key they already share to make sense of what comes back.
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
    /// Where the other end of this session is, in answer to `requestPeerAddress`.
    case peerAddress(RelayPeerAddress)
    /// Whether a Mac is registered, in answer to `hostPresence`.
    ///
    /// `online: false` is a fact about the *relay*, not about the Mac: a Mac can be awake and
    /// reachable on its own network while being registered nowhere. The screen that draws this is
    /// careful not to turn it into the word "offline".
    case hostPresence(deviceID: String, online: Bool)
    case pong
    case error(code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, controlHost, controlPort, videoHost, videoPort
        case sessionTTLSeconds = "sessionTtlSeconds"
        case controlToken, videoToken
        case deviceID = "deviceId"
        case hostID = "hostId"
        case online
        case code, message
        case host, port
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
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            throw RelayProtocolError.unknownMessage(type)
        }
    }

    /// Sixteen bytes, spelled as thirty-two hex digits.
    ///
    /// **Both guards are load-bearing, and one of them used to be wrong.** This asked for
    /// `utf8.count == 32` and then walked the string sixteen times, two *characters* at a time. A
    /// string of thirty-two bytes can be fewer than thirty-two characters (one four-byte emoji
    /// standing in for one of the digits is enough), and the walk then asked for an index past
    /// the end and took the process down with it. A trap, reachable from whatever the relay
    /// sends, in a function whose entire job is to refuse things.
    ///
    /// So the count is in characters, which is the unit the loop actually moves in, and every
    /// character has to be an ASCII hex digit before the loop starts. That second guard is not
    /// only about non-hex input: `UInt8(_:radix:)` accepts a leading `+`, so without it a token
    /// of sixteen `+1`s would decode to sixteen one-bytes and be handed on as if the relay had
    /// sent it.
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
