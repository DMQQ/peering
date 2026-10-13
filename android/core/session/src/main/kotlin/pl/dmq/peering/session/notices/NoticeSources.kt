package pl.dmq.peering.session.notices

import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.pendingApprovals
import pl.dmq.peering.session.terminal.TerminalsState

/** The views the planner reads, taken from the live chat and terminal state. */
object NoticeSources {
    fun chats(state: AgentChatState?): List<ChatView> = state?.sessions.orEmpty().map(::chatView)

    fun terminals(state: TerminalsState?): List<TerminalView> =
        state?.tabs.orEmpty().map { TerminalView(it.id, it.name, it.attention) }

    private fun chatView(session: AgentChatSession): ChatView = ChatView(
        chatID = session.id,
        title = session.title,
        state = session.state,
        loaded = session.historyLoaded,
        pending = pendingApprovals(session.transcript.rows),
        lastReply = session.transcript.rows.lastOrNull { it is TranscriptRow.AssistantText }
            ?.let { (it as TranscriptRow.AssistantText).text },
    )
}
