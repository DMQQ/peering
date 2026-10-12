package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentSessionState

/**
 * A chat stopped on purpose and moved to history. The host writes [NOTICE] on pausing and the phone reads a chat as
 * paused while it is the last row, so the wire needs no field for it.
 */
object AgentPause {
    const val NOTICE = "Stopped and moved to history. Send a message to pick this chat up where it left off."

    fun isPaused(rows: List<TranscriptRow>): Boolean = (rows.lastOrNull() as? TranscriptRow.Notice)?.text == NOTICE
}

val AgentChatSession.isPaused: Boolean get() = AgentPause.isPaused(transcript.rows)

/** What ending a chat does: a quiet chat with a conversation is kept in history, any other is closed. */
enum class AgentEndAction {
    PAUSE,
    CLOSE,
    ;

    companion object {
        fun choose(session: AgentChatSession, hostSupportsPause: Boolean): AgentEndAction {
            val working = session.state == AgentSessionState.WORKING || session.state == AgentSessionState.AWAITING_APPROVAL
            val hasConversation = session.transcript.rows.isNotEmpty()
            return if (hostSupportsPause && hasConversation && !working && !session.isPaused) PAUSE else CLOSE
        }
    }
}
