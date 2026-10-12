package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.AgentEndAction
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.wire.AgentResumableSession

/**
 * The agents hub: the chats on the Mac as cards, and the two-step flow that starts a new one. Chats are not offered
 * when the Mac did not declare chat support, so [agents] is empty then and no flow can open.
 */
class AgentsHubPresenter(
    private val port: AgentsPort,
    declaredAgentIDs: List<String>,
    private val chatSupported: Boolean,
    private val folders: FolderPicker,
    private val recents: FolderRecents,
    clock: Clock,
    scope: CoroutineScope,
) {
    private val agents = if (chatSupported) AgentCatalog.options(declaredAgentIDs) else emptyList()
    private val activity = SessionActivity(clock)
    private val step = MutableStateFlow<NewChatStep>(NewChatStep.Closed)

    private val canImport = chatSupported && port.capabilities.sessionImport
    private val canPause = chatSupported && port.capabilities.pause

    val ui: StateFlow<HubUi> = combine(port.chats, step, recents.paths, port.resumable) { chats, currentStep, folderPaths, listed ->
        derive(chats, currentStep, folderPaths, listed)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.chats.value, NewChatStep.Closed, recents.paths.value, port.resumable.value))

    fun refresh() {
        port.list()
        if (canImport) port.listResumable()
    }

    fun openSession(sessionID: String) = port.select(sessionID)

    fun closeSession(sessionID: String) = port.close(sessionID)

    /** Ends a chat the way the iPhone does: a quiet chat with a conversation moves to history, any other is closed. */
    fun endSession(sessionID: String) {
        val session = port.chats.value.session(sessionID) ?: return
        when (AgentEndAction.choose(session, canPause)) {
            AgentEndAction.PAUSE -> port.pause(sessionID)
            AgentEndAction.CLOSE -> port.close(sessionID)
        }
    }

    /** Continues a conversation started on the computer; false, with nothing sent, while a terminal there may have it open. */
    fun resume(resumableID: String): Boolean {
        if (!canImport) return false
        val target = port.resumable.value.orEmpty().firstOrNull { it.id == resumableID } ?: return false
        if (target.mayBeOpenElsewhere) return false
        port.resume(target)
        recents.record(target.directory)
        return true
    }

    fun beginNewChat() {
        if (chatSupported && agents.isNotEmpty()) step.value = NewChatStep.ChoosingAgent
    }

    fun chooseAgent(agentID: String) {
        if (agents.none { it.id == agentID }) return
        step.value = NewChatStep.ChoosingFolder(agentID)
        folders.open(null)
    }

    /** Starts the chat in the folder the picker is showing; false, with nothing sent, until a listing has arrived. */
    fun startInChosenFolder(): Boolean {
        val chosen = step.value as? NewChatStep.ChoosingFolder ?: return false
        val directory = folders.ui.value.usablePath ?: return false
        port.start(chosen.agentID, directory)
        recents.record(directory)
        step.value = NewChatStep.Closed
        return true
    }

    fun backToAgents() {
        if (step.value is NewChatStep.ChoosingFolder) step.value = NewChatStep.ChoosingAgent
    }

    fun cancelNewChat() {
        step.value = NewChatStep.Closed
    }

    private fun derive(
        chats: AgentChatState,
        currentStep: NewChatStep,
        folderPaths: List<String>,
        listed: List<AgentResumableSession>?,
    ): HubUi {
        val cards = chats.sessions.map { session ->
            val pending = session.pendingApprovalCount()
            SessionCard(
                id = session.id,
                agentID = session.info.agentID,
                title = session.info.title,
                directory = session.info.directory,
                state = session.cardState(pending),
                lastActivityUnix = activity.lastActivityUnix(session),
                pendingApprovals = pending,
                agentName = AgentCatalog.name(session.info.agentID),
                canPause = AgentEndAction.choose(session, canPause) == AgentEndAction.PAUSE,
            )
        }
        activity.forget(chats.sessions.map { it.id }.toSet())
        return HubUi(
            sessions = cards.filter { it.state != SessionCardState.PAUSED }.sortedByDescending { it.lastActivityUnix },
            history = cards.filter { it.state == SessionCardState.PAUSED }.sortedByDescending { it.lastActivityUnix },
            resumable = if (canImport) resumableCards(listed.orEmpty()) else emptyList(),
            canImport = canImport,
            selectedSessionID = chats.selectedSessionID,
            agents = agents,
            newChat = currentStep,
            failure = chats.failure,
            recentFolders = folderPaths,
        )
    }

    private fun resumableCards(listed: List<AgentResumableSession>): List<ResumableCard> {
        val agentIDs = agents.map { it.id }.toSet()
        return listed.filter { it.agentID in agentIDs }
            .sortedByDescending { it.modifiedAt }
            .map {
                ResumableCard(
                    id = it.id,
                    agentID = it.agentID,
                    agentName = AgentCatalog.name(it.agentID),
                    title = it.title,
                    directory = it.directory,
                    modifiedAtUnix = it.modifiedAt.toLong() + APPLE_EPOCH_OFFSET_SECONDS,
                    openElsewhere = it.mayBeOpenElsewhere,
                )
            }
    }

    private companion object {
        /** Seconds from 1970-01-01 to 2001-01-01, the reference the Mac's dates count from. */
        const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L
    }
}
