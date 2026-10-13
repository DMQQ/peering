package pl.dmq.peering.session.agent

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.agent.changes.AgentChangesReducer
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentResumableSession
import pl.dmq.peering.wire.decoded

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

    private val mutableResumable = MutableStateFlow<List<AgentResumableSession>?>(null)

    private val mutableChanges = MutableStateFlow<AgentChangesByChat>(emptyMap())

    val state: StateFlow<AgentChatState> = mutableState.asStateFlow()

    /** What git says about each chat's folder, and the commit or push in flight. */
    val changes: StateFlow<AgentChangesByChat> = mutableChanges.asStateFlow()

    /** Conversations started on the computer that a chat can continue; null until the host has listed them. */
    val resumable: StateFlow<List<AgentResumableSession>?> = mutableResumable.asStateFlow()

    /** The Mac's folder listings, failures and waiting notes. Nothing is buffered for a picker that is not open. */
    val browseEvents: SharedFlow<AgentEvent> = mutableBrowse.asSharedFlow()

    fun onEvent(event: AgentEvent) {
        if (!capabilities.admits(event)) return
        if (event is AgentEvent.Resumable) {
            mutableResumable.value = event.decoded()
            return
        }
        AgentChangesReducer.onEvent(mutableChanges.value, event)?.let {
            mutableChanges.value = it
            return
        }
        if (event is AgentEvent.Failed && refuseChangesWork(event)) return
        if (event is AgentEvent.Closed) mutableChanges.value = AgentChangesReducer.forget(mutableChanges.value, event.sessionID)
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

    /**
     * Answers an ask in any chat, not only the selected one, for a notification button. False when the chat or the ask is
     * gone: it was answered on the computer or another phone, and sending would only be ignored.
     */
    fun answer(sessionID: String, approvalID: String, answer: ApprovalAnswer): Boolean {
        if (!capabilities.chat) return false
        val session = mutableState.value.session(sessionID) ?: return false
        val request = answerRequest(sessionID, pendingApprovals(session.transcript.rows), approvalID, answer) ?: return false
        send(request)
        return true
    }

    fun interrupt() = ifDeclared(capabilities.chat) { mutableState.value.selectedSessionID?.let { send(AgentRequest.Interrupt(it)) } }

    fun close() = ifDeclared(capabilities.chat) { mutableState.value.selectedSessionID?.let { send(AgentRequest.Close(it)) } }

    /** Names the chat on this phone only: the computer's title still says what it runs. Blank names are ignored. */
    fun rename(sessionID: String, name: String) = ifDeclared(capabilities.chat) {
        val trimmed = name.trim()
        val session = mutableState.value.session(sessionID)
        if (trimmed.isNotEmpty() && session != null) {
            mutableState.value = mutableState.value.replacingSession(session.copy(renamedTo = trimmed))
        }
    }

    /** Stops the chat's process and keeps its conversation; the next prompt picks it up. */
    fun pause(sessionID: String) = ifDeclared(capabilities.chat && capabilities.pause) { send(AgentRequest.Pause(sessionID)) }

    fun listResumable() = ifDeclared(capabilities.chat && capabilities.sessionImport) { send(AgentRequest.ListResumable) }

    fun resume(session: AgentResumableSession) = ifDeclared(capabilities.chat && capabilities.sessionImport) {
        send(AgentRequest.Resume(session.agentID, session.cliSessionID))
    }

    fun setModel(sessionID: String, model: String?) =
        ifDeclared(capabilities.modelPicker) { send(AgentRequest.SetModel(sessionID, model)) }

    fun setPermissionMode(sessionID: String, mode: AgentPermissionMode) =
        ifDeclared(capabilities.permissionModes) { send(AgentRequest.SetPermissionMode(sessionID, mode)) }

    /** Asks the Mac to list [path], or its home folder when null. */
    fun browse(path: String?) = ifDeclared(capabilities.chat) { send(AgentRequest.Browse(path)) }

    /** Asks for the folder's git state; the answer arrives as an event. */
    fun loadChanges(sessionID: String) = ifDeclared(capabilities.chat) {
        mutableChanges.value = AgentChangesReducer.askedForChanges(mutableChanges.value, sessionID)
        send(AgentRequest.Changes(sessionID))
    }

    /** Commits exactly [paths] (relative to the chat's folder); one commit or push runs at a time per chat. */
    fun commitChanges(sessionID: String, paths: List<String>, message: String) = ifDeclared(capabilities.chat) {
        val next = AgentChangesReducer.askedToCommit(mutableChanges.value, sessionID) ?: return@ifDeclared
        mutableChanges.value = next
        send(AgentRequest.Commit(sessionID, paths, message))
    }

    fun pushChanges(sessionID: String) = ifDeclared(capabilities.chat) {
        val next = AgentChangesReducer.askedToPush(mutableChanges.value, sessionID) ?: return@ifDeclared
        mutableChanges.value = next
        send(AgentRequest.Push(sessionID))
    }

    private fun refuseChangesWork(event: AgentEvent.Failed): Boolean {
        val sessionID = event.sessionID ?: return false
        val next = AgentChangesReducer.refused(mutableChanges.value, sessionID, event.message) ?: return false
        mutableChanges.value = next
        return true
    }

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
