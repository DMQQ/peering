package pl.dmq.peering.session.agent

/**
 * What an agent chat screen shows. [failure] is a problem not tied to one chat; a chat's own failure lives on
 * its [AgentChatSession].
 */
data class AgentChatState(
    val sessions: List<AgentChatSession> = emptyList(),
    val selectedSessionID: String? = null,
    val failure: String? = null,
) {
    val selected: AgentChatSession? get() = session(selectedSessionID)

    val transcriptRows: List<TranscriptRow> get() = selected?.transcript?.rows.orEmpty()

    val openApprovals: List<PendingApproval> get() = pendingApprovals(transcriptRows)

    val queuedPrompts: List<String> get() = selected?.prompts?.prompts.orEmpty()

    fun session(id: String?): AgentChatSession? = sessions.firstOrNull { it.id == id }

    /** Replaces the chat with the same id, or appends it when the phone has not seen it before. */
    fun replacingSession(session: AgentChatSession): AgentChatState {
        val index = sessions.indexOfFirst { it.id == session.id }
        val updated = if (index < 0) sessions + session else sessions.toMutableList().apply { set(index, session) }
        return copy(sessions = updated)
    }
}
