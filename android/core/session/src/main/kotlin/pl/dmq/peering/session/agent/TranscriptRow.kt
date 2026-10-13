package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentPlanStep
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentTurnSummary

/** One line of a session's conversation. Ids are unique within one [TranscriptState]. */
sealed class TranscriptRow {
    abstract val id: Long

    data class User(override val id: Long, val text: String) : TranscriptRow()

    data class AssistantText(override val id: Long, val text: String) : TranscriptRow()

    data class ToolCall(
        override val id: Long,
        val call: AgentToolCall,
        val status: ToolStatus,
        val output: String?,
        val truncated: Boolean,
    ) : TranscriptRow()

    data class Plan(override val id: Long, val steps: List<AgentPlanStep>) : TranscriptRow()

    data class Notice(override val id: Long, val text: String) : TranscriptRow()

    data class Failure(override val id: Long, val message: String) : TranscriptRow()

    /** A sub-agent's own conversation, filed under the `Task` call that spawned it. */
    data class Subagent(
        override val id: Long,
        val parentCallID: String,
        val transcript: TranscriptState,
    ) : TranscriptRow()

    data class TurnSummary(override val id: Long, val summary: AgentTurnSummary) : TranscriptRow()

    data class Approval(
        override val id: Long,
        val approvalID: String,
        val call: AgentToolCall,
        val reason: String?,
        val status: ApprovalStatus,
    ) : TranscriptRow()
}

sealed class ToolStatus {
    data object Running : ToolStatus()

    /** Waiting on the user; the answer must echo [approvalID]. */
    data class AwaitingApproval(val approvalID: String) : ToolStatus()

    data object Denied : ToolStatus()

    data object Ok : ToolStatus()

    data object Failed : ToolStatus()
}

sealed class ApprovalStatus {
    data object Pending : ApprovalStatus()

    data class Answered(val decision: AgentApprovalDecision) : ApprovalStatus()

    /** The turn ended while the ask was open; the CLI cancelled it. */
    data object Cancelled : ApprovalStatus()
}
