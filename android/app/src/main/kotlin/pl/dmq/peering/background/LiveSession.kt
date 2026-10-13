package pl.dmq.peering.background

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.terminal.TerminalsState
import pl.dmq.peering.ui.wiring.ActiveSession

/** What the background story reads of the running session. The chats and shells exist once the computer has declared them. */
internal data class LiveSession(
    val phase: SessionPhase,
    val hostId: String?,
    val chats: AgentChatState?,
    val terminals: TerminalsState?,
)

/** The chats and shells are looked up again whenever the phase changes, because they appear when the session becomes ready. */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun liveSessions(active: Flow<ActiveSession?>): Flow<LiveSession?> = active.flatMapLatest { session ->
    if (session == null) {
        flowOf(null)
    } else {
        val controller = session.controller
        controller.state.map { it.phase }.distinctUntilChanged().flatMapLatest { phase ->
            val chats: Flow<AgentChatState?> = controller.agentChat?.state ?: flowOf(null)
            val terminals: Flow<TerminalsState?> = controller.terminals?.state ?: flowOf(null)
            combine(chats, terminals) { chat, shells -> LiveSession(phase, session.target.hostId, chat, shells) }
        }
    }
}
