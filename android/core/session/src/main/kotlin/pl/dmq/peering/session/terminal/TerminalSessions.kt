package pl.dmq.peering.session.terminal

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.session.terminal.screen.TerminalEmulator
import pl.dmq.peering.session.terminal.screen.VtScreen
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64

/**
 * The shells of one computer, driven by its events and the user's intents. Events arrive on the reader thread and
 * intents on the main one, so tabs and screens change together under one lock; requests are sent after it is released.
 */
class TerminalSessions(
    private val send: (TerminalRequest) -> Unit,
    private val newEmulator: (columns: Int, rows: Int) -> TerminalEmulator = ::VtScreen,
) {
    private val lock = Any()
    private val screens = HashMap<String, TerminalEmulator>()
    private val mutableState = MutableStateFlow(TerminalsState())

    val state: StateFlow<TerminalsState> = mutableState.asStateFlow()

    /** Asks for the list. Called when the screen opens and again after a reconnect, which replays each shell's output. */
    fun attach() = send(TerminalRequest.ListTerminals)

    fun open() = send(TerminalRequest.Create)

    fun select(id: String) = synchronized(lock) {
        if (mutableState.value.tabs.any { it.id == id }) mutableState.value = mutableState.value.copy(selectedID = id)
    }

    fun input(id: String, bytes: ByteArray) {
        if (bytes.isNotEmpty()) send(TerminalRequest.Input(id, bytes.toBase64()))
    }

    fun input(id: String, text: String) = input(id, text.toByteArray(Charsets.UTF_8))

    /**
     * Rows only grow: a keyboard opening shortens the view, not the shell's screen, and a resize makes the far end
     * redraw everything. The view follows the bottom of a taller screen instead. The size is sent even when unchanged,
     * because the computer's PTY keeps whatever size it was last given.
     */
    fun resize(id: String, columns: Int, rows: Int) {
        val request = synchronized(lock) {
            val tab = mutableState.value.tabs.firstOrNull { it.id == id } ?: return
            val grown = maxOf(tab.rows, rows.coerceAtLeast(1))
            val wide = columns.coerceIn(1, MAX_DIMENSION)
            screens[id]?.resize(wide, grown)
            update(id) { it.copy(columns = wide, rows = grown, revision = it.revision + 1) }
            TerminalRequest.Resize(id, wide, grown.coerceAtMost(MAX_DIMENSION))
        }
        send(request)
    }

    fun close(id: String) = send(TerminalRequest.Close(id))

    fun rename(id: String, name: String) = send(TerminalRequest.Rename(id, name))

    /** The picture of one shell's screen as of now. */
    fun snapshot(id: String): ScreenSnapshot = synchronized(lock) { screens[id]?.snapshot() } ?: ScreenSnapshot.EMPTY

    fun dismissFailure() = synchronized(lock) { mutableState.value = mutableState.value.copy(failure = null) }

    fun onEvent(event: TerminalEvent) = synchronized(lock) {
        when (event) {
            is TerminalEvent.Snapshot -> onList(event.terminals)
            is TerminalEvent.Created -> onCreated(event.terminal)
            is TerminalEvent.Renamed -> update(event.terminal.id) { it.copy(name = event.terminal.name) }
            is TerminalEvent.Output -> onOutput(event)
            is TerminalEvent.Attention -> {
                update(event.sessionID) { it.copy(attention = event.kind) }
                select(event.sessionID)
            }
            is TerminalEvent.Exited -> update(event.sessionID) {
                it.copy(isRunning = false, exitStatus = event.status, revision = it.revision + 1)
            }
            is TerminalEvent.Closed -> onClosed(event.sessionID)
            is TerminalEvent.Failed -> onFailed(event)
            else -> Unit
        }
    }

    /** Output is replayed after a listing, so every screen starts again, at the shape it had, for the replay to land on. */
    private fun onList(infos: List<TerminalSessionInfo>) {
        val known = mutableState.value.tabs.associateBy { it.id }
        val tabs = infos.map { info ->
            val before = known[info.id]
            val columns = before?.columns ?: info.columns ?: DEFAULT_COLUMNS
            val rows = before?.rows ?: info.rows ?: DEFAULT_ROWS
            screens[info.id] = newEmulator(columns, rows)
            TerminalTab(info.id, info.name, info.isRunning, columns, rows, exitStatus = before?.exitStatus?.takeIf { !info.isRunning })
        }
        screens.keys.retainAll(tabs.map { it.id }.toSet())
        val selected = mutableState.value.selectedID?.takeIf { id -> tabs.any { it.id == id } } ?: tabs.firstOrNull()?.id
        mutableState.value = TerminalsState(tabs, selected, loaded = true)
    }

    private fun onCreated(info: TerminalSessionInfo) {
        val columns = info.columns ?: DEFAULT_COLUMNS
        val rows = info.rows ?: DEFAULT_ROWS
        screens[info.id] = newEmulator(columns, rows)
        val tab = TerminalTab(info.id, info.name, info.isRunning, columns, rows)
        val current = mutableState.value
        mutableState.value = current.copy(tabs = current.tabs.filter { it.id != info.id } + tab, selectedID = info.id, loaded = true)
    }

    private fun onOutput(event: TerminalEvent.Output) {
        val screen = screens[event.sessionID] ?: return
        screen.feed(event.dataBytes)
        update(event.sessionID) { it.copy(attention = null, failure = null, revision = it.revision + 1) }
    }

    private fun onClosed(id: String) {
        screens.remove(id)
        val current = mutableState.value
        val tabs = current.tabs.filter { it.id != id }
        val selected = current.selectedID?.takeIf { it != id } ?: tabs.firstOrNull()?.id
        mutableState.value = current.copy(tabs = tabs, selectedID = selected)
    }

    private fun onFailed(event: TerminalEvent.Failed) {
        val id = event.sessionID
        if (id != null && mutableState.value.tabs.any { it.id == id }) {
            update(id) { it.copy(failure = event.message) }
        } else {
            mutableState.value = mutableState.value.copy(failure = event.message)
        }
    }

    private inline fun update(id: String, change: (TerminalTab) -> TerminalTab) {
        val current = mutableState.value
        if (current.tabs.none { it.id == id }) return
        mutableState.value = current.copy(tabs = current.tabs.map { if (it.id == id) change(it) else it })
    }

    private companion object {
        const val DEFAULT_COLUMNS = 80
        const val DEFAULT_ROWS = 24
        const val MAX_DIMENSION = 65_535
    }
}
