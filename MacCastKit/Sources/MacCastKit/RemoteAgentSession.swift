import Foundation
import RemoteCore

/// One chat session as the phone holds it.
///
/// The counterpart of ``RemoteTerminal``: the identifier is the Mac's, the transcript is the
/// drawn conversation, and the two facts that differ from a shell are that a chat's history
/// arrives lazily (a listing carries none of it) and that "running" is a fact about a turn.
public struct RemoteAgentSession: Identifiable, Equatable {
    public let id: UUID
    public var agentID: String
    public var title: String
    public var directory: String
    public var transcript = AgentTranscript()
    public let createdAt: Date
    /// The Mac's own reading of the session, shown until the transcript has events of its own.
    public var infoState: AgentSessionState
    /// What the session runs, as the Mac last said. `nil` is the CLI's own default.
    public var model: String?
    /// Whether the transcript has been asked for. A session from a listing has none yet.
    public var isLoaded = false
    /// The last thing that was asked of this session and did not work, until it speaks again.
    public var failure: String?

    public init(_ info: AgentSessionInfo) {
        id = info.id
        agentID = info.agentID
        title = info.title
        directory = info.directory
        createdAt = info.createdAt
        infoState = info.state
        model = info.model
    }

    /// What the tab is saying about it. The transcript knows more than the listing does: it sees
    /// a turn begin and end, while the listing is a snapshot of the last time the Mac spoke.
    public var state: AgentSessionState {
        isLoaded ? transcript.state : infoState
    }

    public var isEmpty: Bool { transcript.isEmpty }
}
