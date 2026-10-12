import Foundation

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

    /// Whether this host takes ``MessageKind/activityToken`` and pushes Live Activity updates through the relay. Optional and additive: `nil` reads as no.
    public var supportsLiveActivityPush: Bool?

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
        supportsLiveActivityPush: Bool? = nil,
        hostPlatform: String? = nil
    ) {
        self.supportsClientState = supportsClientState
        self.supportsLiveActivityPush = supportsLiveActivityPush
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
