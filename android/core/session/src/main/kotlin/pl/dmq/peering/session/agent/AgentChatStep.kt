package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentRequest

/** The next state and the requests that follow it. The reducers return both, so nothing is sent from inside a fold. */
internal data class AgentChatStep(
    val state: AgentChatState,
    val requests: List<AgentRequest> = emptyList(),
)
