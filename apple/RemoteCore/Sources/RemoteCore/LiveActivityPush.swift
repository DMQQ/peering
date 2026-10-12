import Foundation

/// Which Live Activity a token belongs to.
public enum LiveActivityKind: String, Codable, Sendable, Hashable, CaseIterable {
    case session
    case agentChat
}

/// Which APNs host a token was minted for. A Debug build's tokens work only on the sandbox.
public enum PushEnvironment: String, Codable, Sendable, Hashable {
    case production
    case sandbox
}

/// The body of ``MessageKind/activityToken``: what the phone holds for one Live Activity.
///
/// Both tokens are `null` when the activity has ended. The keys are always written, null included, so another platform can read the shape from a vector.
public struct ActivityTokenPayload: Codable, Sendable, Equatable {
    public var activity: LiveActivityKind
    /// Hex of the per-activity token, `nil` while no activity is running.
    public var pushToken: String?
    /// Hex of the token that lets a server start the activity, `nil` where the system gives none.
    public var pushToStartToken: String?
    public var environment: PushEnvironment

    public init(
        activity: LiveActivityKind,
        pushToken: String?,
        pushToStartToken: String?,
        environment: PushEnvironment
    ) {
        self.activity = activity
        self.pushToken = pushToken
        self.pushToStartToken = pushToStartToken
        self.environment = environment
    }

    public var isEnded: Bool { pushToken == nil && pushToStartToken == nil }

    private enum CodingKeys: String, CodingKey {
        case activity, pushToken, pushToStartToken, environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activity = try container.decode(LiveActivityKind.self, forKey: .activity)
        pushToken = try container.decodeIfPresent(String.self, forKey: .pushToken)
        pushToStartToken = try container.decodeIfPresent(String.self, forKey: .pushToStartToken)
        environment = try container.decode(PushEnvironment.self, forKey: .environment)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activity, forKey: .activity)
        try container.encode(pushToken, forKey: .pushToken)
        try container.encode(pushToStartToken, forKey: .pushToStartToken)
        try container.encode(environment, forKey: .environment)
    }
}

public enum LiveActivityPushSupport {
    /// An older host treats an unknown kind as a protocol error, so the tokens go only to a host that declared it.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// Hex the way the relay reads it: lowercase, two digits a byte.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// A token as sent: even length, hex digits only. Anything else would be a stranger's string forwarded to APNs.
    public static func isPlausible(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 512 && token.count.isMultiple(of: 2)
            && token.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
