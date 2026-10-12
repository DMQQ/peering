package pl.dmq.peering.session.agent

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRequest

/**
 * The agent chat screen's state, driven by Mac events and user intents. Nothing is sent unless the host declared the
 * feature behind the request ([capabilities]). Folder listings are not chat state: they go to [browseEvents], which the
 * folder picker reads while it is open.
 */
class AgentChat(
    val capabilities: AgentCapabilities,
    private val send: (AgentRequest) -> Unit,
) {
    private val mutableState = MutableStateFlow(AgentChatState())
    private val mutableBrowse = MutableSharedFlow<AgentEvent>(extraBufferCapacity = BROWSE_BUFFER)

    val state: StateFlow<AgentChatState> = mutableState.asStateFlow()

    /** The Mac's folder listings, failures and waiting notes. Nothing is buffered for a picker that is not open. */
    val browseEvents: SharedFlow<AgentEvent> = mutableBrowse.asSharedFlow()

    fun onEvent(event: AgentEvent) {
        if (!capabilities.admits(event)) return
        if (event.isBrowseEvent()) {
            mutableBrowse.tryEmit(event)
            return
        }
        commit(AgentChatReducer.onEvent(mutableState.value, event))
    }

    fun list() = ifDeclared(capabilities.chat) { send(AgentRequest.ListSessions) }

    fun start(agentID: String, directory: String?) =
        ifDeclared(capabilities.chat) { send(AgentRequest.Start(agentID, directory)) }

    fun select(sessionID: String) = ifDeclared(capabilities.chat) { commit(AgentChatIntents.select(mutableState.value, sessionID)) }

    fun prompt(text: String) = ifDeclared(capabilities.chat) { commit(AgentChatIntents.prompt(mutableState.value, text)) }

    fun approve(approvalID: String, answer: ApprovalAnswer) =
        ifDeclared(capabilities.chat) { commit(AgentChatIntents.approve(mutableState.value, approvalID, answer)) }

    fun interrupt() = ifDeclared(capabilities.chat) { mutableState.value.selectedSessionID?.let { send(AgentRequest.Interrupt(it)) } }

    fun close() = ifDeclared(capabilities.chat) { mutableState.value.selectedSessionID?.let { send(AgentRequest.Close(it)) } }

    fun setModel(sessionID: String, model: String?) =
        ifDeclared(capabilities.modelPicker) { send(AgentRequest.SetModel(sessionID, model)) }

    fun setPermissionMode(sessionID: String, mode: AgentPermissionMode) =
        ifDeclared(capabilities.permissionModes) { send(AgentRequest.SetPermissionMode(sessionID, mode)) }

    /** Asks the Mac to list [path], or its home folder when null. */
    fun browse(path: String?) = ifDeclared(capabilities.chat) { send(AgentRequest.Browse(path)) }

    private fun commit(step: AgentChatStep) {
        mutableState.value = step.state
        if (capabilities.chat) step.requests.forEach(send)
    }

    private fun AgentEvent.isBrowseEvent(): Boolean =
        this is AgentEvent.Directory || this is AgentEvent.BrowseFailure || this is AgentEvent.BrowseWaiting

    private inline fun ifDeclared(declared: Boolean, action: () -> Unit) {
        if (declared) action()
    }

    private companion object {
        const val BROWSE_BUFFER = 16
    }
}
