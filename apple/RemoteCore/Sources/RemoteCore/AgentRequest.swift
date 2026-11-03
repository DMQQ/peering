import Foundation

/// Requests sent by an authenticated client for an agent chat session.
///
/// Sent only to a Mac that declared ``ServerHello/supportsAgentChat``: an older Mac fails the session on an undecodable request.
public enum AgentRequest: Codable, Equatable, Sendable {
    /// Every session this client owns, as summaries; transcripts come via ``history(sessionID:since:)``.
    case list
    /// Everything after ``since``, in as many ``AgentEvent/replay(sessionID:events:isLast:truncatedAtFront:)``
    /// chunks as it takes.
    case history(sessionID: UUID, since: UInt64)
    /// A new chat. ``directory`` is the folder the agent works in; nil means the Mac's home folder,
    /// the one path the phone cannot work out for itself.
    case start(agentID: String, directory: String?)
    case prompt(sessionID: UUID, text: String)
    /// The user's answer to one approval prompt. A second answer for the same id is ignored.
    case approval(sessionID: UUID, approvalID: String, decision: AgentApprovalDecision)
    /// Stop the turn in flight. The session stays; the next prompt starts a new turn.
    case interrupt(sessionID: UUID)
    /// What the session runs from now on; `nil` restores the CLI's default (Claude changes model in-process, Codex per turn).
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentModelPicker``.
    case setModel(sessionID: UUID, model: String?)
    /// How freely the session may act from now on. Sent only to a Mac that declared
    /// ``ServerHello/supportsAgentPermissionModes``.
    case setPermissionMode(sessionID: UUID, mode: AgentPermissionMode)
    case close(sessionID: UUID)
    /// One folder's contents for the chat picker; needs no shell, unlike ``TerminalRequest/listDirectory(sessionID:path:)``.
    case browse(path: String?)
    /// The session's folder as git sees it, answered with ``AgentEvent/changes(sessionID:report:)``.
    case changes(sessionID: UUID)
    /// Commit exactly ``paths`` (relative to the session's folder) with ``message``. Answered with ``AgentEvent/gitResult(sessionID:result:)`` and a fresh ``AgentEvent/changes(sessionID:report:)``.
    case commit(sessionID: UUID, paths: [String], message: String)
    /// Push the current branch to its own upstream and nothing else; the Mac refuses a detached HEAD or a branch with no upstream.
    case push(sessionID: UUID)
    /// The CLI conversations on this Mac that were not started from this app. Answered with ``AgentEvent/resumable(_:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentSessionImport``.
    case listResumable
    /// A new chat that continues one of ``listResumable``'s conversations, with its past read back from the CLI's own file. Answered with ``AgentEvent/created(_:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentSessionImport``.
    case resume(agentID: String, cliSessionID: String)
    /// The end of one of ``listResumable``'s conversations, to look at without continuing it. Answered with ``AgentEvent/resumablePeek(cliSessionID:events:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentSessionPeek``.
    case peekResumable(cliSessionID: String)
    /// Stops the session's process and keeps the chat, which starts again where it left off on the next prompt. Refused while a turn is running.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentPause``.
    case pause(sessionID: UUID)
    /// A message for the chat: sent at once when it is idle, otherwise held by the Mac and sent when the turn ends, so it goes out with the phone away. The Mac answers every change with ``AgentEvent/queueChanged(sessionID:prompts:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentQueue``.
    case queue(sessionID: UUID, text: String)
    /// Takes the message out of the chat's queue, if it is still there. ``text`` is what the phone saw at ``index``, since the queue may have shifted by the time this arrives.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentQueue``.
    case unqueue(sessionID: UUID, index: Int, text: String)
    /// Whether this phone wants a push only for approvals and questions, not for finished turns. Sent on every ready session and on change.
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentAwayControls``, as are the three below.
    case setAlertPreference(decisionsOnly: Bool)
    /// Nil clears the chat's cap.
    case setSpendingCap(sessionID: UUID, cap: AgentSpendingCap?)
    /// The person sends on the next message a cap held back.
    case releaseHeld(sessionID: UUID)
    /// Allows a plan; with `acceptEditsForTurn` edits then go through unasked until the turn ends, when the mode before the plan returns. Shell commands still ask.
    case approvePlan(sessionID: UUID, approvalID: String, acceptEditsForTurn: Bool)
    /// The folder's branch on GitHub, answered with ``AgentEvent/github(sessionID:report:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentGitHub``, as is the one below.
    case github(sessionID: UUID)
    /// Answered with ``AgentEvent/githubResult(sessionID:result:)`` and a fresh ``AgentEvent/github(sessionID:report:)``.
    case githubAction(sessionID: UUID, action: AgentGitHubAction)
    /// Every routine this client made, answered with ``AgentEvent/routines(_:)``.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentRoutines``, as are the three below. Each is answered with the whole list.
    case listRoutines
    /// Adds the routine, or replaces the one with its id.
    case saveRoutine(AgentRoutine)
    case deleteRoutine(id: UUID)
    /// Starts a run at once, unless one is already going.
    case runRoutineNow(id: UUID)
}
