import Foundation

/// What this device tells the relay about what it has bought, and what it can prove.
///
/// `jwsRepresentation` is the proof: the signed transaction read off the `VerificationResult` that
/// `Transaction.currentEntitlements` yields, which the relay verifies against Apple's root and
/// believes over everything else. `plan` is the claim, read only when there is no proof to check.
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
    /// `proof` is optional on the wire and the relay accepts its absence, which is what lets a
    /// build that predates it keep working. An ID proved once can only be registered by the device
    /// that proved it.
    case registerHost(
        deviceID: String,
        name: String,
        protocolVersion: UInt16,
        proof: RelayDeviceProof? = nil
    )
    /// A request for a session, with whatever this client can say about what it has bought.
    ///
    /// `plan` is a claim and `jwsRepresentation` is the evidence for it: the relay verifies the
    /// receipt against Apple's published root and meters by the product it names, reading the plan
    /// only when no receipt verifies. Both are read leniently, since an absent plan or a receipt
    /// that does not verify means the free allowance rather than a refusal to connect.
    ///
    /// `clientProof`, when present, is what the allowance is keyed on: without it the relay meters
    /// the announced client ID, a string in the app's own storage that starts over on reinstall,
    /// rather than the Keychain key. Optional on the wire, so a build that predates it is metered
    /// the old way rather than refused.
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
    /// Asked with this end's own video token, the only thing either end holds that says which of
    /// the session's two slots it is, so the answer is always the peer.
    ///
    /// `peerAddressUnknown` is the ordinary first answer rather than a failure: a client asks
    /// before it has sent a datagram, so the peer has usually not been heard from yet.
    case requestPeerAddress(videoToken: Data)
    /// Is this Mac registered with the relay right now?
    ///
    /// Bonjour cannot answer this: a Mac reached through the relay was drawn as switched off,
    /// because the green dot came from the local browse. The relay already gives the fact away in
    /// `hostOffline`, so asking costs no session. It is asked while the Connect tab is open and
    /// never in the background, because a phone that asks after three Macs has told the relay which
    /// three it wants.
    case hostPresence(hostID: String)
    case ping
    /// Asks the relay to send an APNs push to a phone that is no longer reachable over the
    /// control channel. Only a registered Mac may send this. The relay holds the APNs key;
    /// this end holds only the device token it received from the phone.
    case notifyDevice(token: String, title: String, body: String)

    private enum CodingKeys: String, CodingKey {
        case type, name, protocolVersion, apiKey, plan, jwsRepresentation
        // Both messages carry a proof under these three names. They are over different strings,
        // which the relay tells apart by the payload's version tag rather than by the field name.
        case publicKey, proof, proofTime
        /// The APNs token, under its own key: `token` is the video token on the peer-address
        /// message, and the relay's `NotifyDevice` reads `device_token`.
        case deviceToken
        case deviceID = "deviceId"
        case hostID = "hostId"
        case clientID = "clientId"
        case videoToken
        case token, title, body
    }


    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .registerHost(let deviceID, let name, let protocolVersion, let proof):
            try container.encode("registerHost", forKey: .type)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(name, forKey: .name)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            // All three or none: the relay treats a partial proof as a message it does not
            // understand rather than salvaging what is there.
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
            // Three fields or none, under the same names the host registration uses. What is signed
            // is not the same, and the relay tells the two apart by their version tag rather than
            // by the field names: this one is over
            // ``RelayDeviceProof/clientPayload(clientID:proofTime:)``.
            if let clientProof {
                try container.encode(clientProof.publicKey, forKey: .publicKey)
                try container.encode(clientProof.signature, forKey: .proof)
                try container.encode(clientProof.proofTime, forKey: .proofTime)
            }
            // Left out rather than sent as null: the relay's spelling of "no plan" and "no receipt"
            // is the field being absent.
            if let plan { try container.encode(plan, forKey: .plan) }
            // A few kilobytes of base64, which the signalling socket's 64 KB message limit has room
            // for; the relay's `MAX_JWS_BYTES` is what refuses an oversized one.
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
        case .notifyDevice(let token, let title, let body):
            try container.encode("notifyDevice", forKey: .type)
            try container.encode(token, forKey: .deviceToken)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
        }
    }

    /// Lowercase hex of sixteen bytes, which is how the relay spells a video token on the wire.
    /// `%02x` is what keeps a leading zero, without which the token is thirty-one characters and
    /// the relay's `unhex`, exact about length, refuses it.
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
/// An observation, not a promise: it is the source address of the peer's most recent video
/// datagram, so it is the peer as its own NAT presents it. Whether that NAT will accept a packet
/// from a third party is a different question, one the two ends settle between themselves.
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
    /// `online: false` is a fact about the relay, not about the Mac: a Mac can be awake and
    /// reachable on its own network while being registered nowhere, so the screen does not turn it
    /// into the word "offline".
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
