import Foundation

/// One JSON value, so a push body can carry an object the relay never reads.
public enum RelayJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RelayJSON])
    case object([String: RelayJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RelayJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RelayJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum RelayActivityEvent: String, Sendable, Equatable, Codable {
    case start
    case update
    case end
}

/// The body of `notifyActivity`: a Live Activity update for the relay to hand to APNs.
public struct RelayActivityPush: Sendable, Equatable, Encodable {
    /// The relay refuses a `contentState` serialised above this.
    public static let maximumContentStateBytes = 3500

    public var activityToken: String
    public var activity: LiveActivityKind
    public var event: RelayActivityEvent
    public var contentState: RelayJSON
    public var staleSeconds: UInt32?
    /// 5 or 10.
    public var priority: Int?
    /// `start` only.
    public var attributesType: String?
    /// `start` only, and not empty.
    public var attributes: RelayJSON?
    public var alertTitle: String?
    public var alertBody: String?
    public var environment: PushEnvironment
    /// `end` only: seconds until the card leaves the Lock Screen. The relay clamps it to 14400, which is also its default.
    public var dismissalSeconds: UInt32?
    /// Up to 64 characters. The relay echoes it in `activityRefused`, so a refusal can be tied to the push it was about.
    public var requestId: String?

    public init(
        activityToken: String,
        activity: LiveActivityKind,
        event: RelayActivityEvent,
        contentState: RelayJSON,
        staleSeconds: UInt32? = nil,
        priority: Int? = nil,
        attributesType: String? = nil,
        attributes: RelayJSON? = nil,
        alertTitle: String? = nil,
        alertBody: String? = nil,
        environment: PushEnvironment,
        dismissalSeconds: UInt32? = nil,
        requestId: String? = nil
    ) {
        self.activityToken = activityToken
        self.activity = activity
        self.event = event
        self.contentState = contentState
        self.staleSeconds = staleSeconds
        self.priority = priority
        self.attributesType = attributesType
        self.attributes = attributes
        self.alertTitle = alertTitle
        self.alertBody = alertBody
        self.environment = environment
        self.dismissalSeconds = dismissalSeconds
        self.requestId = requestId
    }

    /// Whether the state fits the relay's limit once serialised.
    public var contentStateFits: Bool {
        guard let data = try? RelayMessageCodec.encode(contentState) else { return false }
        return data.count <= Self.maximumContentStateBytes
    }
}

/// Why the relay did not send a push. Reasons the relay adds later still decode.
public enum RelayActivityRefusal: Sendable, Equatable, Codable {
    case invalidPayload
    case invalidToken
    case rejected
    case unavailable
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "invalidPayload": self = .invalidPayload
        case "invalidToken": self = .invalidToken
        case "rejected": self = .rejected
        case "unavailable": self = .unavailable
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .invalidPayload: try container.encode("invalidPayload")
        case .invalidToken: try container.encode("invalidToken")
        case .rejected: try container.encode("rejected")
        case .unavailable: try container.encode("unavailable")
        case .other(let raw): try container.encode(raw)
        }
    }
}
