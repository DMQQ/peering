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
    private val selectedAgent = MutableStateFlow(agents.singleOrNull()?.id)

    private val canImport = chatSupported && port.capabilities.sessionImport
    private val canPause = chatSupported && port.capabilities.pause

    val ui: StateFlow<HubUi> = combine(port.chats, step, recents.paths, port.resumable, selectedAgent) { chats, currentStep, folderPaths, listed, agentID ->
        derive(chats, currentStep, folderPaths, listed, agentID)
    }.stateIn(
        scope,
        SharingStarted.Eagerly,
        derive(port.chats.value, NewChatStep.Closed, recents.paths.value, port.resumable.value, selectedAgent.value),
    )

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

    /** Continues a conversation started on the computer; false, with nothing sent, while a terminal there may have it open unless [anyway]. */
    fun resume(resumableID: String, anyway: Boolean = false): Boolean {
        if (!canImport) return false
        val target = port.resumable.value.orEmpty().firstOrNull { it.id == resumableID } ?: return false
        if (target.mayBeOpenElsewhere && !anyway) return false
        port.resume(target)
        recents.record(target.directory)
        return true
    }

    /** The dock's main button: the folder page for the selected agent, or the agent choice while none is selected. */
    fun beginNewChat() {
        if (!chatSupported || agents.isEmpty()) return
        val agentID = selectedAgent.value
        if (agentID == null) {
            step.value = NewChatStep.ChoosingAgent
        } else {
            step.value = NewChatStep.ChoosingFolder(agentID)
            folders.open(null)
        }
    }

    fun openAgentPicker() {
        if (chatSupported && agents.size > 1) step.value = NewChatStep.ChoosingAgent
    }

    /** Selects the agent the dock chats with, and closes the choice if it was open. */
    fun chooseAgent(agentID: String) {
        if (agents.none { it.id == agentID }) return
        selectedAgent.value = agentID
        if (step.value == NewChatStep.ChoosingAgent) step.value = NewChatStep.Closed
    }

    /** A new chat with the same agent in the same folder, as close to continuing one as a CLI offers. */
    fun newChatHere(sessionID: String) {
        val session = port.chats.value.session(sessionID) ?: return
        if (agents.none { it.id == session.info.agentID }) return
        port.start(session.info.agentID, session.info.directory)
        recents.record(session.info.directory)
    }

    /** Starts the chat in the folder the picker is showing; false, with nothing sent, until a listing has arrived. */
    fun startInChosenFolder(): Boolean = startIn(folders.ui.value.usablePath)

    /** Starts the chat in a recent folder without browsing to it first. */
    fun startInRecentFolder(directory: String): Boolean = directory in recents.paths.value && startIn(directory)

    private fun startIn(directory: String?): Boolean {
        val chosen = step.value as? NewChatStep.ChoosingFolder ?: return false
        if (directory == null) return false
        port.start(chosen.agentID, directory)
        recents.record(directory)
        step.value = NewChatStep.Closed
        return true
    }

    fun cancelNewChat() {
        step.value = NewChatStep.Closed
    }

    private fun derive(
        chats: AgentChatState,
        currentStep: NewChatStep,
        folderPaths: List<String>,
        listed: List<AgentResumableSession>?,
        selectedAgentID: String?,
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
                preview = session.lastReplyPreview(),
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
            agentUsage = agents.map { agentUsage(it.id, cards) },
            selectedAgentID = selectedAgentID,
            newChat = currentStep,
            failure = chats.failure,
            recentFolders = folderPaths,
        )
    }

    private fun agentUsage(agentID: String, cards: List<SessionCard>): AgentUsage {
        val mine = cards.filter { it.agentID == agentID }
        val live = mine.filter { it.state != SessionCardState.PAUSED && it.state != SessionCardState.ENDED }
        return AgentUsage(
            agentID = agentID,
            working = live.count { it.state == SessionCardState.WORKING },
            needsYou = live.count { it.state == SessionCardState.NEEDS_YOU },
            open = live.size,
            lastUsedUnix = mine.maxOfOrNull { it.lastActivityUnix },
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
