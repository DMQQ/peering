import Foundation

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
    /// Only a registered Mac may send this. A push the relay does not send is answered with ``RelayServerMessage/activityRefused(_:requestId:)``.
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
        case attributesType, attributes, alertTitle, alertBody, environment, dismissalSeconds, requestId
        case code
        case sessionID = "sessionId"
        case approvalID = "approvalId"
        case options
        case questions
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
            if let answers = action?.answers, !answers.isEmpty { try container.encode(answers, forKey: .options) }
            if let questions = action?.questions, !questions.isEmpty { try container.encode(questions, forKey: .questions) }
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
            try container.encodeIfPresent(push.dismissalSeconds, forKey: .dismissalSeconds)
            try container.encodeIfPresent(push.requestId, forKey: .requestId)
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
