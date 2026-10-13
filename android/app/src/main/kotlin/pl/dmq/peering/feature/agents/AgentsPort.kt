package pl.dmq.peering.feature.agents

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentResumableSession

/**
 * What the agents screens ask of the session layer. The session controller implements it by sending the matching
 * request. [browseEvents] carries the Mac's folder listings and failures, for the [FolderPicker].
 */
interface AgentsPort {
    val chats: StateFlow<AgentChatState>

    /** What the computer declared; each feature degrades when its flag is absent. */
    val capabilities: AgentCapabilities

    /** Conversations started on the computer that a chat can continue; null until listed. */
    val resumable: StateFlow<List<AgentResumableSession>?>

    val browseEvents: Flow<AgentEvent>

    /** What git says about each chat's folder, and the commit or push in flight. */
    val changes: StateFlow<AgentChangesByChat>

    /** The web preview's way to the computer's loopback; null where the preview is not offered. */
    val preview: PreviewProxyClient?

    fun list()

    fun start(agentID: String, directory: String?)

    fun select(sessionID: String)

    fun close(sessionID: String)

    fun prompt(sessionID: String, text: String)

    /** Names the chat on this phone only. */
    fun rename(sessionID: String, name: String)

    fun approve(sessionID: String, approvalID: String, answer: ApprovalAnswer)

    fun interrupt(sessionID: String)

    fun pause(sessionID: String)

    fun listResumable()

    fun resume(session: AgentResumableSession)

    fun setPermissionMode(sessionID: String, mode: AgentPermissionMode)

    fun setModel(sessionID: String, model: String?)

    /** Asks the Mac to list [path], or its home folder when null. */
    fun browse(path: String?)

    fun loadChanges(sessionID: String)

    fun commitChanges(sessionID: String, paths: List<String>, message: String)

    fun pushChanges(sessionID: String)
}
