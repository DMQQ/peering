package pl.dmq.peering.feature.agents

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.wire.AgentPermissionMode

class FakeAgentsPort(initial: AgentChatState = AgentChatState()) : AgentsPort {
    val chatState = MutableStateFlow(initial)
    val calls = mutableListOf<String>()

    override val chats: StateFlow<AgentChatState> get() = chatState

    override fun list() {
        calls += "list"
    }

    override fun start(agentID: String, directory: String?) {
        calls += "start:$agentID:$directory"
    }

    override fun select(sessionID: String) {
        calls += "select:$sessionID"
    }

    override fun close(sessionID: String) {
        calls += "close:$sessionID"
    }

    override fun prompt(sessionID: String, text: String) {
        calls += "prompt:$sessionID:$text"
    }

    override fun approve(sessionID: String, approvalID: String, answer: ApprovalAnswer) {
        calls += "approve:$sessionID:$approvalID:$answer"
    }

    override fun interrupt(sessionID: String) {
        calls += "interrupt:$sessionID"
    }

    override fun setPermissionMode(sessionID: String, mode: AgentPermissionMode) {
        calls += "mode:$sessionID:$mode"
    }

    override fun setModel(sessionID: String, model: String?) {
        calls += "model:$sessionID:$model"
    }

    override fun browse(path: String?) {
        calls += "browse:$path"
    }
}
