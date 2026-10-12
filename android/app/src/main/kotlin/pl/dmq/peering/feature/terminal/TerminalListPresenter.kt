package pl.dmq.peering.feature.terminal

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.session.terminal.TerminalsState
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.wire.TerminalAttentionKind

/** What a card's status corner says. Failure and a shell waiting on the person win over running. */
enum class TerminalCardState { RUNNING, PASSWORD, CONFIRMATION, FAILED, EXITED }

/** One shell on the list page. The output is not here: it is read separately and at a slower pace than it arrives. */
data class TerminalCard(val id: String, val name: String, val state: TerminalCardState) {
    val isRunning: Boolean get() = state == TerminalCardState.RUNNING || needsYou
    val needsYou: Boolean get() = state == TerminalCardState.PASSWORD || state == TerminalCardState.CONFIRMATION
}

/** One agent on the list page, and how long ago it was last started from here (null if never). */
data class LauncherCard(val agent: TerminalAgent, val lastUsed: LaunchAge?)

/** One past start. */
data class HistoryRow(val agentID: String, val title: String, val computer: String, val age: LaunchAge)

/**
 * The Terminals tab as a list page and a pushed shell page. Only the shape of the shells is read here; the output
 * of each one reaches its card through [previewLines], so a busy shell never rebuilds the list.
 */
class TerminalListPresenter(
    private val sessions: TerminalSessions,
    private val history: AgentLaunchHistory,
    private val computerName: () -> String = { "" },
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val shell = MutableStateFlow(false)
    private var knownBeforeCreate: Set<String>? = null
    private var commandForNewShell: String? = null

    /** True while a shell is pushed over the list. */
    val inShell: StateFlow<Boolean> = shell.asStateFlow()

    fun open(id: String) {
        sessions.select(id)
        shell.value = true
    }

    fun back() {
        shell.value = false
    }

    fun create() {
        knownBeforeCreate = sessions.state.value.tabs.mapTo(HashSet()) { it.id }
        sessions.open()
    }

    /** A new shell that is given the agent's command and Return once it exists, so the agent runs where the person can see it. */
    fun start(agent: TerminalAgent) {
        history.record(AgentLaunch(agent.id, nowMillis(), computerName()))
        commandForNewShell = agent.command
        create()
    }

    fun clearHistory() = history.clear()

    fun end(id: String) = sessions.close(id)

    fun rename(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isNotEmpty()) sessions.rename(id, trimmed)
    }

    /** Pushes the shell a create asked for once it arrives, and returns to the list when no shell is left. */
    fun onState(state: TerminalsState) {
        val before = knownBeforeCreate
        val created = before?.let { known -> state.tabs.firstOrNull { it.id !in known } }
        if (created != null) {
            knownBeforeCreate = null
            commandForNewShell?.let { sessions.input(created.id, it + "\r") }
            commandForNewShell = null
            open(created.id)
        } else if (state.failure != null) {
            knownBeforeCreate = null
            commandForNewShell = null
        } else if (shell.value && state.loaded && state.tabs.isEmpty()) {
            shell.value = false
        }
    }

    companion object {
        private const val PREVIEW_LINES = 4
        private const val PREVIEW_WIDTH = 90

        /** Every agent while the computer has no list to give, none while it is still answering, else the installed ones. */
        fun launchers(state: TerminalsState, launches: List<AgentLaunch>, nowMillis: Long): List<LauncherCard> {
            val installed = state.installedAgents
            val shown = when {
                installed != null -> TerminalAgent.all.filter { it.command in installed }
                state.agentListPending -> emptyList()
                else -> TerminalAgent.all
            }
            return shown.map { agent ->
                val last = launches.firstOrNull { it.agentID == agent.id }
                LauncherCard(agent, last?.let { LaunchAge.between(nowMillis, it.atMillis) })
            }
        }

        fun historyRows(launches: List<AgentLaunch>, nowMillis: Long): List<HistoryRow> = launches.map {
            HistoryRow(it.agentID, TerminalAgent.byId(it.agentID)?.name ?: it.agentID, it.computer, LaunchAge.between(nowMillis, it.atMillis))
        }

        fun cards(state: TerminalsState): List<TerminalCard> = state.tabs.map { TerminalCard(it.id, it.name, cardState(it)) }

        private fun cardState(tab: TerminalTab): TerminalCardState = when {
            tab.failure != null -> TerminalCardState.FAILED
            !tab.isRunning -> TerminalCardState.EXITED
            tab.attention == TerminalAttentionKind.PASSWORD -> TerminalCardState.PASSWORD
            tab.attention != null -> TerminalCardState.CONFIRMATION
            else -> TerminalCardState.RUNNING
        }

        /** The last few lines of the visible screen that say something, clipped to what a card holds. */
        fun previewLines(snapshot: ScreenSnapshot): List<String> =
            snapshot.lines.takeLast(snapshot.rows)
                .map { it.text.trim() }
                .filter { it.isNotEmpty() }
                .takeLast(PREVIEW_LINES)
                .map { it.take(PREVIEW_WIDTH) }
    }
}
