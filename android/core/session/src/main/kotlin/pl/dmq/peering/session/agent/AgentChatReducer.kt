package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo

/** Folds one Mac event into the chat list. Pure: the caller decides what to send. */
internal object AgentChatReducer {
    fun onEvent(state: AgentChatState, event: AgentEvent): AgentChatStep = when (event) {
        is AgentEvent.Snapshot -> snapshot(state, event.sessions)
        is AgentEvent.Created -> created(state, event.session)
        is AgentEvent.Stream -> stream(state, event)
        is AgentEvent.Replay -> replay(state, event)
        is AgentEvent.Closed -> closed(state, event.sessionID)
        is AgentEvent.Failed -> failed(state, event)
        is AgentEvent.ModelChanged -> updateInfo(state, event.sessionID) { it.copy(model = event.model) }
        is AgentEvent.UsageChanged -> updateInfo(state, event.sessionID) { it.copy(usage = event.usage) }
        is AgentEvent.PermissionModeChanged -> updateInfo(state, event.sessionID) { it.copy(permissionMode = event.mode) }
        is AgentEvent.Directory,
        is AgentEvent.BrowseFailure,
        is AgentEvent.BrowseWaiting,
        is AgentEvent.Changes,
        is AgentEvent.GitResult,
        is AgentEvent.Resumable,
        -> AgentChatStep(state)
    }

    /**
     * Keeps what the phone already read: a chat it holds keeps its conversation and queue. The selection moves to
     * the first chat when the old one is gone, and the chats being shown ask for their history again.
     */
    private fun snapshot(state: AgentChatState, infos: List<AgentSessionInfo>): AgentChatStep {
        val previous = state.sessions.associateBy { it.id }
        val selectedID = state.selectedSessionID?.takeIf { id -> infos.any { it.id == id } } ?: infos.firstOrNull()?.id
        val requests = mutableListOf<AgentRequest>()
        val sessions = infos.map { info ->
            val kept = previous[info.id]?.copy(info = info, historyRequested = false, failure = null)
                ?: AgentChatSession(info)
            if (kept.historyLoaded || kept.id == selectedID) {
                val (asked, request) = kept.askHistory()
                requests += request
                asked
            } else {
                kept
            }
        }
        return AgentChatStep(AgentChatState(sessions, selectedID, state.failure), requests)
    }

    /** A new chat is selected and read from the start, whether or not the phone held an older copy of it. */
    private fun created(state: AgentChatState, info: AgentSessionInfo): AgentChatStep {
        val base = state.session(info.id)?.copy(info = info) ?: AgentChatSession(info)
        val asked = base.copy(historyRequested = true)
        return AgentChatStep(
            state.replacingSession(asked).copy(selectedSessionID = info.id),
            listOf(AgentRequest.History(info.id, since = 0)),
        )
    }

    private fun closed(state: AgentChatState, sessionID: String): AgentChatStep {
        val remaining = state.sessions.filterNot { it.id == sessionID }
        val selected = if (state.selectedSessionID == sessionID) remaining.firstOrNull()?.id else state.selectedSessionID
        return AgentChatStep(state.copy(sessions = remaining, selectedSessionID = selected))
    }

    /** A failure about one chat is shown on that chat; one about no chat, or an unknown one, is shown for the whole list. */
    private fun failed(state: AgentChatState, event: AgentEvent.Failed): AgentChatStep {
        val session = state.session(event.sessionID)
            ?: return AgentChatStep(state.copy(failure = event.message))
        return AgentChatStep(state.replacingSession(session.copy(failure = event.message)))
    }

    private fun updateInfo(
        state: AgentChatState,
        sessionID: String,
        change: (AgentSessionInfo) -> AgentSessionInfo,
    ): AgentChatStep {
        val session = state.session(sessionID) ?: return AgentChatStep(state)
        return AgentChatStep(state.replacingSession(session.copy(info = change(session.info))))
    }
}
