import Foundation

public enum AgentEvent: Codable, Equatable, Sendable {
    case snapshot([AgentSessionInfo])
    case created(AgentSessionInfo)
    case stream(sessionID: UUID, event: AgentStreamEvent)
    /// A chunk of the history ``AgentRequest/history(sessionID:since:)`` asked for; chunked because a conversation is megabytes on a shared channel.
    /// ``truncatedAtFront`` says the Mac's buffer no longer holds the start, so the client can say so.
    case replay(sessionID: UUID, events: [AgentStreamEvent], isLast: Bool, truncatedAtFront: Bool)
    case directory(path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    case browseFailure(path: String, message: String)
    /// The Mac has not answered a ``AgentRequest/browse(path:)`` yet, and says why: it may be waiting on a permission dialog only someone at the Mac can answer. The listing still follows as ``directory(path:entries:truncated:)`` once it is allowed.
    case browseWaiting(path: String, message: String)
    case changes(sessionID: UUID, report: AgentChangesReport)
    case gitResult(sessionID: UUID, result: AgentGitResult)
    case closed(sessionID: UUID)
    /// The model the session now runs, sent when the picker changes it and whenever the CLI
    /// itself announces one. `nil` is the CLI's default.
    case modelChanged(sessionID: UUID, model: String?)
    /// The mode the session is now in, once the CLI has taken it. Sent only to a client that
    /// declared ``ClientHello/supportsAgentPermissionModes``.
    case permissionModeChanged(sessionID: UUID, mode: AgentPermissionMode)
    /// What the session has used, sent when a turn ends. Sent only to a client that declared
    /// ``ClientHello/supportsAgentUsage``.
    case usageChanged(sessionID: UUID, usage: AgentUsage)
    case failed(sessionID: UUID?, message: String)
    /// The answer to ``AgentRequest/listResumable``, newest first.
    case resumable([AgentResumableSession])
    /// The answer to ``AgentRequest/peekResumable(cliSessionID:)``: the last of the conversation, indexed from 1 so it reads as a transcript. Empty when the file is gone.
    case resumablePeek(cliSessionID: String, events: [AgentStreamEvent])
    /// The messages waiting behind the chat's running turn, in the order they will go; empty when none are. Sent only to a client that declared ``ClientHello/supportsAgentQueue``.
    case queueChanged(sessionID: UUID, prompts: [String])
    /// Sent only in answer to ``AgentRequest/github(sessionID:)`` or ``AgentRequest/githubAction(sessionID:action:)``, which an older client never sends.
    case github(sessionID: UUID, report: AgentGitHubReport)
    case githubResult(sessionID: UUID, result: AgentGitHubResult)
    /// Sent only in answer to a routine request.
    case routines([AgentRoutine])
}
