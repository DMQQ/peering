import Foundation

public struct ClientHello: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientName: String
    public var protocolVersion: UInt16
    /// Advisory only: the host decides, since only it knows its pin store.
    public var wantsPairing: Bool

    /// Declared, not implied by version: this build and the one before both speak version 16. Optional and additive: `nil` reads as no.
    public var supportsClipboardImages: Bool?

    /// Declared like ``supportsClipboardImages``: an older client cannot decode the frame kind.
    public var supportsTextFocus: Bool?

    public var supportsFieldState: Bool?

    /// Declared like ``supportsTextFocus``: an older client cannot decode the frame kind.
    public var supportsPointerReport: Bool?

    /// Declared in both directions: the Mac streams events, so it is the Mac that must restrain itself when the phone is older. `nil` reads as no.
    public var supportsAgentChat: Bool?

    /// Whether this client reads ``AgentEvent/permissionModeChanged(sessionID:mode:)``.
    public var supportsAgentPermissionModes: Bool?

    /// Whether this client reads ``AgentEvent/usageChanged(sessionID:usage:)``.
    public var supportsAgentUsage: Bool?

    /// Honoured only for a client the Mac already trusts.
    public var resumeSource: CaptureSource?

    /// Set only by a phone that dialled a Mac by its ID and holds no pin for it, so the Mac may still trust the phone's key while the phone has forgotten the Mac. Without it that pair was stuck: the Mac answered "already paired" and the phone refused to proceed. `nil` reads as no, which is every older client.
    public var lostPairing: Bool?

    /// Set when the person chose to displace the phone that is using this Mac. Optional and additive: an older Mac ignores it and keeps turning the newcomer away. Honoured only for a client whose key the Mac has pinned.
    public var takesOver: Bool?

    /// Which platform this client runs on, for a host whose behaviour differs by it (`"android"`, `"ios"`). Optional and additive: `nil` is an iPhone build from before this field.
    public var clientPlatform: String?

    /// The codecs this client decodes, best first (`"hevc"`, `"h264"`). Optional and additive: `nil` is a client from before this field, which decodes both.
    public var videoCodecs: [String]?

    /// A random tag for this connection attempt, kept across automatic resumes, so analytics on the phone and the Mac can be joined. Optional and additive: `nil` is a client from before this field, and a host that does not know it ignores the key.
    public var sessionRef: String?

    /// Whether the Mac skips pairing for a client whose key it has pinned. The one place the rule lives, because the Mac cannot unit-test its handshake.
    public static func hostTreatsAsPaired(clientKeyIsPinned: Bool, lostPairing: Bool?) -> Bool {
        clientKeyIsPinned && lostPairing != true
    }

    public init(
        clientID: String,
        clientName: String,
        protocolVersion: UInt16,
        wantsPairing: Bool,
        supportsClipboardImages: Bool? = nil,
        supportsTextFocus: Bool? = nil,
        supportsFieldState: Bool? = nil,
        supportsPointerReport: Bool? = nil,
        supportsAgentChat: Bool? = nil,
        supportsAgentPermissionModes: Bool? = nil,
        supportsAgentUsage: Bool? = nil,
        resumeSource: CaptureSource? = nil,
        lostPairing: Bool? = nil,
        takesOver: Bool? = nil,
        clientPlatform: String? = nil,
        videoCodecs: [String]? = nil,
        sessionRef: String? = nil
    ) {
        self.sessionRef = sessionRef
        self.lostPairing = lostPairing
        self.takesOver = takesOver
        self.clientPlatform = clientPlatform
        self.videoCodecs = videoCodecs
        self.clientID = clientID
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.wantsPairing = wantsPairing
        self.supportsClipboardImages = supportsClipboardImages
        self.supportsTextFocus = supportsTextFocus
        self.supportsFieldState = supportsFieldState
        self.supportsPointerReport = supportsPointerReport
        self.supportsAgentChat = supportsAgentChat
        self.supportsAgentPermissionModes = supportsAgentPermissionModes
        self.supportsAgentUsage = supportsAgentUsage
        self.resumeSource = resumeSource
    }
}

public struct PairingCommit: Codable, Sendable, Equatable {
    public var commitment: Data

    public init(commitment: Data) {
        self.commitment = commitment
    }
}

/// The value behind a ``PairingCommit``, checked against the earlier commitment before use, so a
/// peer that changed its mind after seeing the other side's contribution is caught here.
public struct PairingReveal: Codable, Sendable, Equatable {
    public var ephemeralPublicKey: Data
    public var nonce: Data

    public init(ephemeralPublicKey: Data, nonce: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

public struct PairConfirm: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// ``PairingSAS/proof(secret:transcript:)``; absent when the digits were typed rather than scanned.
    public var proof: Data?

    public init(accepted: Bool, proof: Data? = nil) {
        self.accepted = accepted
        self.proof = proof
    }
}

public struct PairResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// Present when `accepted` is false: a bare failure beside two screens looks like a bug.
    public var reason: String?

    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

/// A standing condition on the host, or `nil` when there is none.
public struct NoticePayload: Codable, Sendable, Equatable {
    public let message: String?

    /// An SF Symbol picked by the host, which knows which thing is wrong (sleeping and disconnected screens both look black).
    public let symbol: String?

    /// Set while the Mac is locked: the display showing its lock screen. Present even when `message` is nil so a phone already on that display knows when the lock ends.
    public let lockedDisplayID: UInt32?

    /// A stable name for the condition, so a client can act on it without reading the sentence. Optional on the wire: a peer built before it neither sends nor needs it.
    public let code: String?

    public init(message: String?, symbol: String? = nil, lockedDisplayID: UInt32? = nil, code: String? = nil) {
        self.message = message
        self.symbol = symbol
        self.lockedDisplayID = lockedDisplayID
        self.code = code
    }
}

public struct ClipboardPayload: Codable, Sendable, Equatable {
    /// A field rather than "whichever is set": both could be present and the ends would disagree on which wins.
    public enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    public var kind: Kind
    public var text: String?
    /// PNG only: macOS puts a screenshot on the pasteboard as TIFF, which iOS cannot read.
    public var image: Data?

    public init(kind: Kind, text: String? = nil, image: Data? = nil) {
        self.kind = kind
        self.text = text
        self.image = image
    }

    public static func text(_ text: String) -> ClipboardPayload {
        ClipboardPayload(kind: .text, text: text)
    }

    public static func image(_ png: Data) -> ClipboardPayload {
        ClipboardPayload(kind: .image, image: png)
    }

    public var carriedImage: Data? {
        guard kind == .image, let image, image.count <= ClipboardLimits.maxImageBytes else { return nil }
        return image
    }

    /// An older Mac sends `{"text": ...}` with no `kind`, which the synthesised decoder would refuse; absent kind means text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
    }
}

/// A pong is matched to its ping by this number so a late one is discarded. It is a payload, not a new kind, so a Mac that ignores it answers with an empty pong.
public struct PingPayload: Codable, Sendable, Equatable {
    public let sequence: UInt64

    public init(sequence: UInt64) {
        self.sequence = sequence
    }
}

public struct ErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    /// The user pressed Stop on the Mac. A client must not reconnect: nothing is listening.
    public static let hostStoppedCode = "hostStopped"

    /// Another phone is using this Mac. The newcomer is told so by code rather than by sentence, so it can offer to take over in its own language.
    public static let anotherDeviceCode = "anotherDevice"

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum MessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
