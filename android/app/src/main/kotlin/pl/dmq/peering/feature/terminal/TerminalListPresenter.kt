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

/**
 * The Terminals tab as a list page and a pushed shell page. Only the shape of the shells is read here; the output
 * of each one reaches its card through [previewLines], so a busy shell never rebuilds the list.
 */
class TerminalListPresenter(private val sessions: TerminalSessions) {
    private val shell = MutableStateFlow(false)
    private var knownBeforeCreate: Set<String>? = null

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
            open(created.id)
        } else if (shell.value && state.loaded && state.tabs.isEmpty()) {
            shell.value = false
        }
    }

    companion object {
        private const val PREVIEW_LINES = 4
        private const val PREVIEW_WIDTH = 90

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
