package pl.dmq.peering.feature.agents.routines

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.feature.agents.AgentCatalog
import pl.dmq.peering.feature.agents.AgentOption
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.feature.agents.FolderPicker
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.session.agent.routines.AgentRoutineDraft
import pl.dmq.peering.session.agent.routines.RoutineCadence
import pl.dmq.peering.session.agent.routines.RoutineIntervalUnit
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine

/** Which page of the routines screen is showing. The editor and the folder page both carry the draft being made. */
sealed interface RoutinesPage {
    data object List : RoutinesPage

    data class Editor(val draft: AgentRoutineDraft, val isNew: Boolean) : RoutinesPage

    data class Folder(val draft: AgentRoutineDraft, val isNew: Boolean) : RoutinesPage
}

data class RoutinesUi(
    val routines: List<AgentRoutine>?,
    val failure: String?,
    val page: RoutinesPage,
    val agents: List<AgentOption>,
)

/** The routines screen: the Mac's routines, and the editor that makes or changes one. Nothing reaches the Mac until [save]. */
class RoutinesPresenter(
    private val port: AgentsPort,
    declaredAgentIDs: List<String>,
    private val folders: FolderPicker,
    private val recents: FolderRecents,
    scope: CoroutineScope,
) {
    private val agents = AgentCatalog.options(declaredAgentIDs)
    private val page = MutableStateFlow<RoutinesPage>(RoutinesPage.List)

    val ui: StateFlow<RoutinesUi> = combine(port.routines, port.routineFailure, page) { routines, failure, current ->
        RoutinesUi(routines, failure, current, agents)
    }.stateIn(scope, SharingStarted.Eagerly, RoutinesUi(port.routines.value, port.routineFailure.value, page.value, agents))

    val recentFolders: StateFlow<List<String>> get() = recents.paths

    fun refresh() = port.listRoutines()

    fun runNow(id: String) = port.runRoutineNow(id)

    fun startNew() {
        val agent = agents.firstOrNull() ?: return
        page.value = RoutinesPage.Editor(AgentRoutineDraft.new(agent.id, modes(agent.id)), isNew = true)
    }

    fun edit(routine: AgentRoutine) {
        page.value = RoutinesPage.Editor(AgentRoutineDraft.of(routine), isNew = false)
    }

    /** The modes a chat with this agent listed, or every mode when none is open to ask; the Mac refuses one its CLI lacks. */
    fun modes(agentID: String): List<AgentPermissionMode> =
        port.chats.value.sessions.firstOrNull { it.info.agentID == agentID && !it.info.permissionModes.isNullOrEmpty() }
            ?.info?.permissionModes ?: AgentPermissionMode.entries

    fun change(transform: (AgentRoutineDraft) -> AgentRoutineDraft) = page.update { current ->
        if (current is RoutinesPage.Editor) current.copy(draft = transform(current.draft)) else current
    }

    fun chooseAgent(agentID: String) {
        val modes = modes(agentID)
        change { it.withAgent(agentID, modes) }
    }

    fun setCadence(cadence: RoutineCadence) = change { it.copy(cadence = cadence) }

    fun setUnit(unit: RoutineIntervalUnit) = change { it.withUnit(unit) }

    fun chooseFolder() {
        val current = page.value as? RoutinesPage.Editor ?: return
        page.value = RoutinesPage.Folder(current.draft, current.isNew)
        folders.open(current.draft.directory)
    }

    /** Takes the folder the picker is showing; false, with nothing changed, until a listing has arrived. */
    fun useChosenFolder(): Boolean = useFolder(folders.ui.value.usablePath)

    fun useRecentFolder(directory: String): Boolean = directory in recents.paths.value && useFolder(directory)

    private fun useFolder(directory: String?): Boolean {
        val current = page.value as? RoutinesPage.Folder ?: return false
        if (directory == null) return false
        page.value = RoutinesPage.Editor(current.draft.copy(directory = directory), current.isNew)
        return true
    }

    /** One step back: the folder page to the editor, the editor to the list. False when already on the list. */
    fun back(): Boolean {
        when (val current = page.value) {
            RoutinesPage.List -> return false
            is RoutinesPage.Editor -> page.value = RoutinesPage.List
            is RoutinesPage.Folder -> page.value = RoutinesPage.Editor(current.draft, current.isNew)
        }
        return true
    }

    fun save() {
        val current = page.value as? RoutinesPage.Editor ?: return
        if (current.draft.problem != null) return
        port.saveRoutine(current.draft.routine)
        page.value = RoutinesPage.List
    }

    fun delete() {
        val current = page.value as? RoutinesPage.Editor ?: return
        if (current.isNew) return
        port.deleteRoutine(current.draft.id)
        page.value = RoutinesPage.List
    }
}
