package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentToolCall

/** An ask the user has not answered, as the transcript shows it. Only the Mac can end it by another route. */
data class PendingApproval(
    val approvalID: String,
    val call: AgentToolCall,
    val reason: String?,
)

/** The user's answer to one ask, before it is sent. */
sealed class ApprovalAnswer {
    data object Allow : ApprovalAnswer()

    data object Deny : ApprovalAnswer()

    /** One chosen label per question, in the order the questions were asked. */
    data class Choose(val answers: List<String>) : ApprovalAnswer()

    fun toDecision(): AgentApprovalDecision = when (this) {
        is Allow -> AgentApprovalDecision.Allow
        is Deny -> AgentApprovalDecision.Deny
        is Choose -> AgentApprovalDecision.Choose(answers)
    }
}

/** The asks still open in [rows]. An ask the Mac resolved, from this phone or another client, is no longer pending. */
fun pendingApprovals(rows: List<TranscriptRow>): List<PendingApproval> = rows
    .filterIsInstance<TranscriptRow.Approval>()
    .filter { it.status == ApprovalStatus.Pending }
    .map { PendingApproval(it.approvalID, it.call, it.reason) }

/**
 * The request that answers [approvalID], or null when no pending ask has that id: it was already answered,
 * withdrawn by the turn ending, or resolved on the Mac. Sending it anyway would only be ignored by the Mac.
 */
fun answerRequest(
    sessionID: String,
    pending: List<PendingApproval>,
    approvalID: String,
    answer: ApprovalAnswer,
): AgentRequest.Approval? {
    if (pending.none { it.approvalID == approvalID }) return null
    return AgentRequest.Approval(sessionID, approvalID, answer.toDecision())
}
