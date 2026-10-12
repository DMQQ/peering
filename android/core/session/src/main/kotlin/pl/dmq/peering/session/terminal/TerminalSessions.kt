package pl.dmq.peering.session.terminal

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
 *
 * Output is parsed on the reader thread. With a [scope], the picture of each changed screen is built there too, at most
 * once per [FRAME_MILLIS], and published through [frames]; without one every output publishes at once.
 */
class TerminalSessions(
    private val send: (TerminalRequest) -> Unit,
    private val newEmulator: (columns: Int, rows: Int) -> TerminalEmulator = ::VtScreen,
    private val scope: CoroutineScope? = null,
    private val listsAgents: () -> Boolean = { false },
) {
    private val lock = Any()
    private val screens = HashMap<String, TerminalEmulator>()
    private val frames = HashMap<String, MutableStateFlow<ScreenSnapshot>>()
    private val dirty = HashSet<String>()
    private var pendingFrame: Job? = null
    private val mutableState = MutableStateFlow(TerminalsState())

    val state: StateFlow<TerminalsState> = mutableState.asStateFlow()

    /** Asks for the list. Called when the screen opens and again after a reconnect, which replays each shell's output. */
    fun attach() = send(TerminalRequest.ListTerminals)

    /** Asks which agent commands the computer has. Never sent to a computer that did not declare the list: it could not decode it. */
    fun refreshAgents() {
        if (!listsAgents()) return
        synchronized(lock) { mutableState.value = mutableState.value.copy(agentListPending = true) }
        send(TerminalRequest.ListAgents)
    }

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
            update(id) { it.copy(columns = wide, rows = grown) }
            markChanged(id)
            TerminalRequest.Resize(id, wide, grown.coerceAtMost(MAX_DIMENSION))
        }
        send(request)
    }

    fun close(id: String) = send(TerminalRequest.Close(id))

    fun rename(id: String, name: String) = send(TerminalRequest.Rename(id, name))

    /** The picture of one shell's screen, republished as its output arrives. Reading it never touches the emulator. */
    fun frames(id: String): StateFlow<ScreenSnapshot> = synchronized(lock) { frameFlow(id) }

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
                it.copy(isRunning = false, exitStatus = event.status)
            }
            is TerminalEvent.Closed -> onClosed(event.sessionID)
            is TerminalEvent.Agents -> mutableState.value =
                mutableState.value.copy(installedAgents = event.installed.toSet(), agentListPending = false)
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
            frameFlow(info.id).value = ScreenSnapshot.EMPTY
            TerminalTab(info.id, info.name, info.isRunning, columns, rows, exitStatus = before?.exitStatus?.takeIf { !info.isRunning })
        }
        screens.keys.retainAll(tabs.map { it.id }.toSet())
        frames.keys.retainAll(screens.keys)
        val selected = mutableState.value.selectedID?.takeIf { id -> tabs.any { it.id == id } } ?: tabs.firstOrNull()?.id
        mutableState.value = mutableState.value.copy(tabs = tabs, selectedID = selected, loaded = true, failure = null)
    }

    private fun onCreated(info: TerminalSessionInfo) {
        val columns = info.columns ?: DEFAULT_COLUMNS
        val rows = info.rows ?: DEFAULT_ROWS
        screens[info.id] = newEmulator(columns, rows)
        frameFlow(info.id).value = ScreenSnapshot.EMPTY
        val tab = TerminalTab(info.id, info.name, info.isRunning, columns, rows)
        val current = mutableState.value
        mutableState.value = current.copy(tabs = current.tabs.filter { it.id != info.id } + tab, selectedID = info.id, loaded = true)
    }

    private fun onOutput(event: TerminalEvent.Output) {
        val screen = screens[event.sessionID] ?: return
        screen.feed(event.dataBytes)
        val tab = mutableState.value.tabs.firstOrNull { it.id == event.sessionID }
        if (tab != null && (tab.attention != null || tab.failure != null)) {
            update(event.sessionID) { it.copy(attention = null, failure = null) }
        }
        markChanged(event.sessionID)
    }

    private fun frameFlow(id: String): MutableStateFlow<ScreenSnapshot> =
        frames.getOrPut(id) { MutableStateFlow(screens[id]?.snapshot() ?: ScreenSnapshot.EMPTY) }

    private fun markChanged(id: String) {
        if (scope == null) {
            screens[id]?.let { frameFlow(id).value = it.snapshot() }
            return
        }
        dirty += id
        if (pendingFrame == null) {
            pendingFrame = scope.launch {
                delay(FRAME_MILLIS)
                publishDirty()
            }
        }
    }

    private fun publishDirty() = synchronized(lock) {
        pendingFrame = null
        dirty.forEach { id -> screens[id]?.let { frameFlow(id).value = it.snapshot() } }
        dirty.clear()
    }

    private fun onClosed(id: String) {
        screens.remove(id)
        frames.remove(id)
        dirty.remove(id)
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
        const val FRAME_MILLIS = 16L
        const val DEFAULT_COLUMNS = 80
        const val DEFAULT_ROWS = 24
        const val MAX_DIMENSION = 65_535
    }
}
