package pl.dmq.peering.widget

import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.wire.AgentSessionState

/** Maps the chats the phone holds to the plain values the widget needs. */
object AgentChatEntries {
    fun from(hostId: String?, sessions: List<AgentChatSession>, nowSeconds: Long): List<AgentChatEntry> = sessions.map { session ->
        AgentChatEntry(
            id = session.id,
            hostId = hostId,
            title = session.info.title,
            folder = session.info.directory.trimEnd('/').substringAfterLast('/'),
            tone = tone(session),
            updatedAtSeconds = nowSeconds,
        )
    }

    private fun tone(session: AgentChatSession): AgentChatTone = when {
        session.failure != null -> AgentChatTone.FAILED
        else -> when (session.state) {
            AgentSessionState.AWAITING_APPROVAL -> AgentChatTone.NEEDS_YOU
            AgentSessionState.WORKING -> AgentChatTone.WORKING
            AgentSessionState.FAILED -> AgentChatTone.FAILED
            AgentSessionState.IDLE, AgentSessionState.EXITED -> AgentChatTone.FINISHED
        }
    }
}
