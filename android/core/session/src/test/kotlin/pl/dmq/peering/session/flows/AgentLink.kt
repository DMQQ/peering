package pl.dmq.peering.session.flows

import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.wire.AgentRequest

/**
 * One phone's connection to a [ScriptedAgentHost]. Requests the chat sends wait in a queue until [pump] delivers them,
 * and the host's answers go back to the chat in the order they were given.
 */
class AgentLink(private val host: ScriptedAgentHost) {
    val sent = mutableListOf<AgentRequest>()
    private val outbox = mutableListOf<AgentRequest>()
    val chat = AgentChat(AgentCapabilities(chat = true)) { outbox += it }

    fun pump() {
        while (outbox.isNotEmpty()) {
            val request = outbox.removeAt(0)
            sent += request
            host.reply(request).forEach(chat::onEvent)
        }
    }
}
