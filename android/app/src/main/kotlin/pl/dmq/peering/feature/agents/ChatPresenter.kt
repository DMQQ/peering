package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.AgentEndAction
import pl.dmq.peering.wire.AgentSessionState

/** What the chat screen's top bar and empty state need from the selected chat. */
data class ChatUi(
    val sessionID: String?,
    val title: String,
    val directory: String,
    val agentName: String,
    val agentID: String,
    val usageSupported: Boolean,
    val chip: ContextChip?,
    val usage: UsageUi,
    val canPause: Boolean,
    val ended: Boolean,
    val showEmptyState: Boolean,
)

/**
 * The selected chat as its screen frames it. Usage is shown only when the computer declared it; "stop and move to
 * history" only when it declared pause and the chat is quiet with a conversation.
 */
class ChatPresenter(
    private val port: AgentsPort,
    scope: CoroutineScope,
) {
    val ui: StateFlow<ChatUi> = port.chats.map(::derive).stateIn(scope, SharingStarted.Eagerly, derive(port.chats.value))

    /** Stops the chat's process and keeps its conversation; false when nothing was sent. */
    fun pause(): Boolean {
        val current = ui.value
        val sessionID = current.sessionID ?: return false
        if (!current.canPause) return false
        port.pause(sessionID)
        return true
    }

    fun close() {
        ui.value.sessionID?.let(port::close)
    }

    fun rename(name: String) {
        ui.value.sessionID?.let { port.rename(it, name) }
    }

    fun suggest(text: String) {
        val sessionID = ui.value.sessionID ?: return
        port.prompt(sessionID, text)
    }

    private fun derive(chats: AgentChatState): ChatUi {
        val session = chats.selected
        val usageSupported = port.capabilities.usage
        val usage = session?.info?.usage
        val state = session?.state
        return ChatUi(
            sessionID = session?.id,
            title = session?.title.orEmpty(),
            directory = session?.info?.directory.orEmpty(),
            agentName = session?.let { AgentCatalog.name(it.info.agentID) }.orEmpty(),
            agentID = session?.info?.agentID.orEmpty(),
            usageSupported = usageSupported,
            chip = if (usageSupported) ContextChip.of(usage) else null,
            usage = UsageUi.of(usage),
            canPause = session != null && port.capabilities.chat && canPause(session),
            ended = state == AgentSessionState.EXITED || state == AgentSessionState.FAILED,
            showEmptyState = session != null && session.historyLoaded && session.transcript.rows.isEmpty() &&
                session.prompts.prompts.isEmpty(),
        )
    }

    private fun canPause(session: AgentChatSession): Boolean =
        AgentEndAction.choose(session, hostSupportsPause = port.capabilities.pause) == AgentEndAction.PAUSE
}
