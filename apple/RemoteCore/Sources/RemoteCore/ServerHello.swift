import Foundation

/// Does not carry the host's public key: the client takes it from the TLS certificate it received, so a man-in-the-middle cannot make both screens agree.
public struct ServerHello: Codable, Sendable, Equatable {
    public var serverID: String
    public var hostName: String
    public var protocolVersion: UInt16
    public var alreadyPaired: Bool
    /// Physical interface MACs for Wake-on-LAN, colon-separated hex.
    public var macAddresses: [String]?

    /// Not a version fact: the host sends `VirtualDisplay.isAvailable`, since an OS without the private API has nothing to offer. `nil` reads as no.
    public var supportsVirtualDisplayManagement: Bool?

    /// A phone uses this to suppress its duplicate local banner. `nil` reads as false.
    public var pushesTerminalAlertsWhileConnected: Bool?

    /// Which agents this host chats with. `nil` reads as Claude Code and Codex only.
    public var agentChatAgents: [String]?

    /// Which platform this host runs on (`"macos"`, `"windows"`). A client may use it to choose key codes and to hide what only a Mac does.
    public var hostPlatform: String?

    public init(
        serverID: String,
        hostName: String,
        protocolVersion: UInt16,
        alreadyPaired: Bool,
        macAddresses: [String]? = nil,
        supportsVirtualDisplayManagement: Bool? = nil,
        pushesTerminalAlertsWhileConnected: Bool? = nil,
        agentChatAgents: [String]? = nil,
        hostPlatform: String? = nil
    ) {
        self.serverID = serverID
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.alreadyPaired = alreadyPaired
        self.macAddresses = macAddresses
        self.supportsVirtualDisplayManagement = supportsVirtualDisplayManagement
        self.pushesTerminalAlertsWhileConnected = pushesTerminalAlertsWhileConnected
        self.agentChatAgents = agentChatAgents
        self.hostPlatform = hostPlatform
    }
}
