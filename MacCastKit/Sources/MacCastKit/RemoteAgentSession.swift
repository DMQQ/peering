import Foundation
import RemoteCore

/// One chat session as the phone holds it. History arrives lazily, and "running" is a fact about a turn.
public struct RemoteAgentSession: Identifiable, Equatable {
    public let id: UUID
    public var agentID: String
    public var title: String
    public var directory: String
    public var transcript = AgentTranscript()
    public let createdAt: Date
    public var infoState: AgentSessionState
    public var model: String?
    public var permissionMode: AgentPermissionMode?
    public var permissionModes: [AgentPermissionMode]
    public var usage: AgentUsage?
    public var isLoaded = false
    public var failure: String?

    public init(_ info: AgentSessionInfo) {
        id = info.id
        agentID = info.agentID
        title = info.title
        directory = info.directory
        createdAt = info.createdAt
        infoState = info.state
        model = info.model
        permissionMode = info.permissionMode
        permissionModes = info.permissionModes ?? []
        usage = info.usage
    }

    /// The transcript sees turns begin and end; the listing is only a snapshot.
    public var state: AgentSessionState {
        isLoaded ? transcript.state : infoState
    }

    public var isEmpty: Bool { transcript.isEmpty }
}
