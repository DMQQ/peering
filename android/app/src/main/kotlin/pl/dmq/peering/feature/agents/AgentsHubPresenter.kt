package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.ports.Clock

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

    val ui: StateFlow<HubUi> = combine(port.chats, step, recents.paths) { chats, currentStep, folderPaths ->
        derive(chats, currentStep, folderPaths)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.chats.value, NewChatStep.Closed, recents.paths.value))

    fun refresh() = port.list()

    fun openSession(sessionID: String) = port.select(sessionID)

    fun closeSession(sessionID: String) = port.close(sessionID)

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

    private fun derive(chats: AgentChatState, currentStep: NewChatStep, folderPaths: List<String>): HubUi {
        val cards = chats.sessions.map { session ->
            val pending = session.pendingApprovalCount()
            SessionCard(
                id = session.id,
                title = session.info.title,
                directory = session.info.directory,
                state = session.cardState(pending),
                lastActivityUnix = activity.lastActivityUnix(session),
                pendingApprovals = pending,
            )
        }
        activity.forget(chats.sessions.map { it.id }.toSet())
        return HubUi(
            sessions = cards.sortedByDescending { it.lastActivityUnix },
            selectedSessionID = chats.selectedSessionID,
            agents = agents,
            newChat = currentStep,
            failure = chats.failure,
            recentFolders = folderPaths,
        )
    }
}
