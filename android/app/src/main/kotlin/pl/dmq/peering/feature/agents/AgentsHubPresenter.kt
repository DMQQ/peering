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
    clock: Clock,
    scope: CoroutineScope,
) {
    private val agents = if (chatSupported) AgentCatalog.options(declaredAgentIDs) else emptyList()
    private val activity = SessionActivity(clock)
    private val step = MutableStateFlow<NewChatStep>(NewChatStep.Closed)

    val ui: StateFlow<HubUi> = combine(port.chats, step) { chats, currentStep -> derive(chats, currentStep) }
        .stateIn(scope, SharingStarted.Eagerly, derive(port.chats.value, NewChatStep.Closed))

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

    /** Starts the chat in the folder the picker is showing. Nothing happens until a listing has arrived. */
    fun startInChosenFolder() {
        val chosen = step.value as? NewChatStep.ChoosingFolder ?: return
        val directory = folders.ui.value.usablePath ?: return
        port.start(chosen.agentID, directory)
        step.value = NewChatStep.Closed
    }

    fun backToAgents() {
        if (step.value is NewChatStep.ChoosingFolder) step.value = NewChatStep.ChoosingAgent
    }

    fun cancelNewChat() {
        step.value = NewChatStep.Closed
    }

    private fun derive(chats: AgentChatState, currentStep: NewChatStep): HubUi {
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
        )
    }
}
