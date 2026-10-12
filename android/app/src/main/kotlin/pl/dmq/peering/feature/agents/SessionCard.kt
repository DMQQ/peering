package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.pendingApprovals
import pl.dmq.peering.wire.AgentSessionState

/** One chat as the hub shows it. [lastActivityUnix] is seconds since the Unix epoch. */
data class SessionCard(
    val id: String,
    val title: String,
    val directory: String,
    val state: SessionCardState,
    val lastActivityUnix: Long,
    val pendingApprovals: Int,
)

enum class SessionCardState {
    WORKING,
    NEEDS_YOU,
    IDLE,
    ENDED,
    FAILED,
}

internal fun AgentChatSession.cardState(pendingApprovals: Int): SessionCardState = when {
    pendingApprovals > 0 || state == AgentSessionState.AWAITING_APPROVAL -> SessionCardState.NEEDS_YOU
    state == AgentSessionState.WORKING -> SessionCardState.WORKING
    state == AgentSessionState.FAILED -> SessionCardState.FAILED
    state == AgentSessionState.EXITED -> SessionCardState.ENDED
    else -> SessionCardState.IDLE
}

internal fun AgentChatSession.pendingApprovalCount(): Int = pendingApprovals(transcript.rows).size
