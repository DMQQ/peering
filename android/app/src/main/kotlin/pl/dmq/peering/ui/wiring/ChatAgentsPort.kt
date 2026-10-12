package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChat
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentResumableSession

/**
 * The agents screens over the session's agent chat. The chat acts on the selected session, so each call that names a
 * session selects it first.
 */
internal class ChatAgentsPort(private val chat: AgentChat) : AgentsPort {
    override val chats: StateFlow<AgentChatState> get() = chat.state

    override val capabilities: AgentCapabilities get() = chat.capabilities

    override val resumable: StateFlow<List<AgentResumableSession>?> get() = chat.resumable

    override val browseEvents: Flow<AgentEvent> get() = chat.browseEvents

    override val changes: StateFlow<AgentChangesByChat> get() = chat.changes

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

    override fun pause(sessionID: String) = chat.pause(sessionID)

    override fun listResumable() = chat.listResumable()

    override fun resume(session: AgentResumableSession) = chat.resume(session)

    override fun setPermissionMode(sessionID: String, mode: AgentPermissionMode) = chat.setPermissionMode(sessionID, mode)

    override fun setModel(sessionID: String, model: String?) = chat.setModel(sessionID, model)

    override fun browse(path: String?) = chat.browse(path)

    override fun loadChanges(sessionID: String) = chat.loadChanges(sessionID)

    override fun commitChanges(sessionID: String, paths: List<String>, message: String) =
        chat.commitChanges(sessionID, paths, message)

    override fun pushChanges(sessionID: String) = chat.pushChanges(sessionID)
}
