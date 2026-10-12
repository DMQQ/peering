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

    /// Which platform this client runs on, for a host whose behaviour differs by it (`"android"`, `"ios"`). Optional and additive: `nil` is an iPhone build from before this field.
    public var clientPlatform: String?

    /// The codecs this client decodes, best first (`"hevc"`, `"h264"`). Optional and additive: `nil` is a client from before this field, which decodes both.
    public var videoCodecs: [String]?

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
        clientPlatform: String? = nil,
        videoCodecs: [String]? = nil
    ) {
        self.lostPairing = lostPairing
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

/// Does not carry the host's public key: the client takes it from the TLS certificate it received, so a man-in-the-middle cannot make both screens agree.
public struct ServerHello: Codable, Sendable, Equatable {
    public var serverID: String
    public var hostName: String
    public var protocolVersion: UInt16
    public var alreadyPaired: Bool
    /// Physical interface MACs for Wake-on-LAN, colon-separated hex.
    public var macAddresses: [String]?
    /// A capability, not a version bump: an older Mac keeps streaming. The client sends the command only on an explicit `true`; `nil` reads as no.
    public var supportsVideoPause: Bool?

    /// One flag covers both directions. `nil` reads as no; the command is sent only on an explicit `true`.
    public var supportsClipboardImages: Bool?

    /// A capability: `CaptureSource` gains a case an older Mac cannot decode, so a mosaic is sent only on an explicit `true`.
    public var supportsMosaic: Bool?

    /// An un-updated Mac throws on the refresh command, so the client sends it only on an explicit `true`.
    public var supportsSourceThumbnails: Bool?

    /// Sent only on an explicit `true`; `nil` reads as no.
    public var supportsDeviceOrientation: Bool?

    /// Not simply the software version: the host sends `VirtualDisplay.isAvailable`, since an OS without the private API has nothing to offer. `nil` reads as no.
    public var supportsVirtualDisplayManagement: Bool?

    /// A phone uses this to suppress its duplicate local banner. `nil` reads as false so an older Mac keeps the local path.
    public var pushesTerminalAlertsWhileConnected: Bool?

    /// An older Mac cannot decode ``TerminalRequest/agents``, so the phone asks only on an explicit `true` and shows every agent otherwise.
    public var supportsAgentList: Bool?

    /// An older Mac cannot decode ``AgentRequest`` or its new message kinds; a chat starts only on an explicit `true`.
    public var supportsAgentChat: Bool?

    /// An older Mac cannot *create* a browsing scope and refuses the request it cannot decode, so the hub's file browser is offered only on an explicit `true`.
    public var supportsFileBrowser: Bool?

    /// The picker is drawn only on an explicit `true`.
    public var supportsAgentModelPicker: Bool?

    /// `nil` is a Mac from before this list, which chats with Claude Code and Codex only.
    public var agentChatAgents: [String]?

    /// Whether this Mac takes ``AgentRequest/setPermissionMode(sessionID:mode:)``. Optional and
    /// additive: `nil` reads as no, and the toggle is drawn only on an explicit `true`.
    public var supportsAgentPermissionModes: Bool?

    /// Whether this Mac reports what a session has used. Optional and additive: `nil` reads as no,
    /// and the usage sheet is offered only on an explicit `true`.
    public var supportsAgentUsage: Bool?

    /// Whether this Mac lists and continues conversations started in a terminal. Optional and
    /// additive: `nil` reads as no, and the list is offered only on an explicit `true`.
    public var supportsAgentSessionImport: Bool?

    /// Whether this Mac takes ``AgentRequest/pause(sessionID:)``. Optional and additive: `nil` reads as no.
    public var supportsAgentPause: Bool?

    /// Whether this host takes ``MessageKind/clientState``. Optional and additive: `nil` reads as no, and a client sends the notice only on an explicit `true`.
    public var supportsClientState: Bool?

    /// Which platform this host runs on (`"macos"`, `"windows"`). Optional and additive: `nil` is a Mac from before this field. A client may use it to choose key codes and to hide what only a Mac does.
    public var hostPlatform: String?

    public init(
        serverID: String,
        hostName: String,
        protocolVersion: UInt16,
        alreadyPaired: Bool,
        macAddresses: [String]? = nil,
        supportsVideoPause: Bool? = nil,
        supportsClipboardImages: Bool? = nil,
        supportsMosaic: Bool? = nil,
        supportsSourceThumbnails: Bool? = nil,
        supportsDeviceOrientation: Bool? = nil,
        supportsVirtualDisplayManagement: Bool? = nil,
        pushesTerminalAlertsWhileConnected: Bool? = nil,
        supportsAgentList: Bool? = nil,
        supportsAgentChat: Bool? = nil,
        supportsFileBrowser: Bool? = nil,
        supportsAgentModelPicker: Bool? = nil,
        agentChatAgents: [String]? = nil,
        supportsAgentPermissionModes: Bool? = nil,
        supportsAgentUsage: Bool? = nil,
        supportsAgentSessionImport: Bool? = nil,
        supportsAgentPause: Bool? = nil,
        supportsClientState: Bool? = nil,
        hostPlatform: String? = nil
    ) {
        self.supportsClientState = supportsClientState
        self.hostPlatform = hostPlatform
        self.serverID = serverID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.alreadyPaired = alreadyPaired
        self.macAddresses = macAddresses
        self.supportsVideoPause = supportsVideoPause
        self.supportsClipboardImages = supportsClipboardImages
        self.supportsMosaic = supportsMosaic
        self.supportsSourceThumbnails = supportsSourceThumbnails
        self.supportsDeviceOrientation = supportsDeviceOrientation
        self.supportsVirtualDisplayManagement = supportsVirtualDisplayManagement
        self.supportsAgentList = supportsAgentList
        self.supportsAgentChat = supportsAgentChat
        self.supportsFileBrowser = supportsFileBrowser
        self.supportsAgentModelPicker = supportsAgentModelPicker
        self.agentChatAgents = agentChatAgents
        self.supportsAgentPermissionModes = supportsAgentPermissionModes
        self.supportsAgentUsage = supportsAgentUsage
        self.supportsAgentSessionImport = supportsAgentSessionImport
        self.supportsAgentPause = supportsAgentPause
        self.pushesTerminalAlertsWhileConnected = pushesTerminalAlertsWhileConnected
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
