import Foundation

/// One thing that happened in an agent session, in the one shape both CLI adapters produce.
///
/// The index is monotonic per session: the client applies an event only if its index is greater than the last applied, so a replay racing live output is exact. Indices start at 1; `since: 0` means everything.
public struct AgentStreamEvent: Codable, Equatable, Sendable {
    public let index: UInt64
    public let payload: Payload

    public init(index: UInt64, payload: Payload) {
        self.index = index
        self.payload = payload
    }

    public indirect enum Payload: Codable, Equatable, Sendable {
        /// The CLI is up. ``cliSessionID`` is the id to resume with after a restart, nil if none yet.
        case sessionReady(agentID: String, cliSessionID: String?, model: String?, directory: String)
        /// What the user said, from the CLI's own echo where it has one, so a replay rebuilds the conversation.
        case userPrompt(text: String)
        case turnStarted
        /// A piece of the reply as it arrives. Coalesced by the host rather than sent per token.
        case textDelta(text: String)
        /// The reply block, whole and authoritative: the client replaces what the deltas built.
        case textFinal(text: String)
        case toolStarted(call: AgentToolCall)
        /// A tool call's outcome. ``output`` is truncated by the host; ``truncated`` says so.
        case toolFinished(callID: String, ok: Bool, output: String?, truncated: Bool)
        case approvalRequested(approvalID: String, call: AgentToolCall, reason: String?)
        case approvalResolved(approvalID: String, decision: AgentApprovalDecision)
        case turnFinished(summary: AgentTurnSummary)
        /// Worth a line in the transcript but not a failure.
        case notice(text: String)
        case failure(message: String)
        case sessionExited(status: Int32)
        /// Something a sub-agent did, filed under the `Task` call that spawned it.
        case child(parentCallID: String, event: Payload)
    }
}
