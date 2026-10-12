package pl.dmq.peering.feature.agents

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentResumableSession

class FakeAgentsPort(
    initial: AgentChatState = AgentChatState(),
    override val capabilities: AgentCapabilities = AgentCapabilities(chat = true, modelPicker = true, permissionModes = true, usage = true, sessionImport = true, pause = true),
) : AgentsPort {
    val chatState = MutableStateFlow(initial)
    val resumableList = MutableStateFlow<List<AgentResumableSession>?>(null)
    val calls = mutableListOf<String>()

    val changesState = MutableStateFlow<AgentChangesByChat>(emptyMap())

    override val preview: PreviewProxyClient? = null

    override val changes: StateFlow<AgentChangesByChat> get() = changesState

    override val chats: StateFlow<AgentChatState> get() = chatState

    override val resumable: StateFlow<List<AgentResumableSession>?> get() = resumableList

    override val browseEvents: Flow<AgentEvent> get() = emptyFlow()

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

    override fun rename(sessionID: String, name: String) {
        calls += "rename:$sessionID:$name"
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

    override fun pause(sessionID: String) {
        calls += "pause:$sessionID"
    }

    override fun listResumable() {
        calls += "listResumable"
    }

    override fun resume(session: AgentResumableSession) {
        calls += "resume:${session.agentID}:${session.cliSessionID}"
    }

    override fun loadChanges(sessionID: String) {
        calls += "changes:$sessionID"
    }

    override fun commitChanges(sessionID: String, paths: List<String>, message: String) {
        calls += "commit:$sessionID:${paths.joinToString(",")}:$message"
    }

    override fun pushChanges(sessionID: String) {
        calls += "push:$sessionID"
    }
}
