package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

/**
 * One chat as the phone holds it. [historyLoaded] is set once the Mac has replayed the conversation;
 * [historyRequested] is set while a history request is outstanding, so one gap or selection asks once.
 */
data class AgentChatSession(
    val info: AgentSessionInfo,
    val transcript: TranscriptState = TranscriptState(),
    val prompts: PromptQueue = PromptQueue(),
    val historyLoaded: Boolean = false,
    val historyRequested: Boolean = false,
    val failure: String? = null,
) {
    val id: String get() = info.id

    val state: AgentSessionState get() = info.state

    val needsHistory: Boolean get() = !historyRequested && (!historyLoaded || transcript.needsHistory)

    fun markWorking(): AgentChatSession = copy(
        info = info.copy(state = AgentSessionState.WORKING),
        transcript = transcript.copy(sessionState = AgentSessionState.WORKING),
    )
}
