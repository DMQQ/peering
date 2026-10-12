package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.wire.AgentPermissionMode

/**
 * The agents screens over the session's agent chat. The chat acts on the selected session, so each call that names a
 * session selects it first. Changing a session's model or permission mode and asking for folders are not carried by the
 * chat yet, so those calls do nothing; the screens reach them only from controls the host has not declared.
 */
internal class ChatAgentsPort(private val chat: AgentChat) : AgentsPort {
    override val chats: StateFlow<AgentChatState> get() = chat.state

    override fun list() = chat.list()

    override fun start(agentID: String, directory: String?) = chat.start(agentID, directory)

    override fun select(sessionID: String) = chat.select(sessionID)

    override fun close(sessionID: String) {
        chat.select(sessionID)
        chat.close()
    }

    override fun prompt(sessionID: String, text: String) {
        chat.select(sessionID)
        chat.prompt(text)
    }

    override fun approve(sessionID: String, approvalID: String, answer: ApprovalAnswer) {
        chat.select(sessionID)
        chat.approve(approvalID, answer)
    }

    override fun interrupt(sessionID: String) {
        chat.select(sessionID)
        chat.interrupt()
    }

    override fun setPermissionMode(sessionID: String, mode: AgentPermissionMode) = Unit

    override fun setModel(sessionID: String, model: String?) = Unit

    override fun browse(path: String?) = Unit
}
