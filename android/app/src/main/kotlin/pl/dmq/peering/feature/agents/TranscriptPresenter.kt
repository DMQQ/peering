package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.wire.AgentSessionState

/**
 * The selected chat's transcript as the list draws it: its rows, the prompts waiting behind the turn, which tool cards
 * are open, and whether the list is following the newest row.
 */
class TranscriptPresenter(
    private val chats: StateFlow<AgentChatState>,
    scope: CoroutineScope,
) {
    private val expandedTools = MutableStateFlow<Set<Long>>(emptySet())
    private val sticking = MutableStateFlow(StickToBottom())

    val ui: StateFlow<TranscriptUi> = combine(chats, expandedTools, sticking) { chatState, expanded, stick ->
        derive(chatState, expanded, stick)
    }.stateIn(scope, SharingStarted.Eagerly, derive(chats.value, emptySet(), StickToBottom()))

    fun toggleTool(rowID: Long) {
        expandedTools.update { if (rowID in it) it - rowID else it + rowID }
    }

    fun onUserScrolled(atBottom: Boolean) {
        val rowCount = chats.value.transcriptRows.size
        sticking.update { it.userScrolled(atBottom, rowCount) }
    }

    /** Called when the user sends a prompt or taps the jump to the newest row: the list follows again. */
    fun followLatest() {
        sticking.update { it.followLatest() }
    }

    private fun derive(chatState: AgentChatState, expanded: Set<Long>, stick: StickToBottom): TranscriptUi {
        val selected = chatState.selected
        val rows = chatState.transcriptRows
        val state = selected?.state
        return TranscriptUi(
            sessionID = selected?.id,
            rows = rows,
            queuedPrompts = chatState.queuedPrompts,
            expandedToolIDs = expanded,
            following = stick.following,
            unseenRows = stick.unseenRows(rows.size),
            truncatedAtFront = selected?.transcript?.truncatedAtFront == true,
            loadingHistory = selected != null && !selected.historyLoaded,
            working = state == AgentSessionState.WORKING || state == AgentSessionState.AWAITING_APPROVAL,
        )
    }
}
