package pl.dmq.peering.session.agent

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest

/**
 * The agent chat screen's state, driven by Mac events and user intents. Nothing is sent unless the host declared
 * [supportsAgentChat]; events are still applied, since the host only sends them when it supports chats.
 */
class AgentChat(
    private val supportsAgentChat: Boolean,
    private val send: (AgentRequest) -> Unit,
) {
    private val mutableState = MutableStateFlow(AgentChatState())

    val state: StateFlow<AgentChatState> = mutableState.asStateFlow()

    fun onEvent(event: AgentEvent) {
        commit(AgentChatReducer.onEvent(mutableState.value, event))
    }

    fun list() = whenSupported { send(AgentRequest.ListSessions) }

    fun start(agentID: String, directory: String?) = whenSupported { send(AgentRequest.Start(agentID, directory)) }

    fun select(sessionID: String) = whenSupported { commit(AgentChatIntents.select(mutableState.value, sessionID)) }

    fun prompt(text: String) = whenSupported { commit(AgentChatIntents.prompt(mutableState.value, text)) }

    fun approve(approvalID: String, answer: ApprovalAnswer) =
        whenSupported { commit(AgentChatIntents.approve(mutableState.value, approvalID, answer)) }

    fun interrupt() = whenSupported { mutableState.value.selectedSessionID?.let { send(AgentRequest.Interrupt(it)) } }

    fun close() = whenSupported { mutableState.value.selectedSessionID?.let { send(AgentRequest.Close(it)) } }

    private fun commit(step: AgentChatStep) {
        mutableState.value = step.state
        if (supportsAgentChat) step.requests.forEach(send)
    }

    private inline fun whenSupported(action: () -> Unit) {
        if (supportsAgentChat) action()
    }
}
