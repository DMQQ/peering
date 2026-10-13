package pl.dmq.peering.ssh.bridge

import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshShell
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Speaks the terminal screens' request and event language over SSH shells, so the renderer, the key deck and the tab
 * strip written for a computer's shells serve a server's too. Calls arrive one at a time on a single worker.
 */
internal class SshShellBridge(
    private val connection: SshConnection,
    private val emit: (TerminalEvent) -> Unit,
    private val newId: () -> String = { UUID.randomUUID().toString().uppercase() },
) {
    private class Entry(val number: Int, var name: String, var columns: Int, var rows: Int) {
        var shell: SshShell? = null

        /** Written by the reader thread when the shell ends, read by the worker. */
        @Volatile
        var isRunning = true
    }

    private val shells = ConcurrentHashMap<String, Entry>()
    private var opened = 0

    fun handle(request: TerminalRequest) {
        when (request) {
            TerminalRequest.ListTerminals -> emit(TerminalEvent.Snapshot(shells.entries.sortedBy { it.value.number }.map { info(it.key, it.value) }))
            TerminalRequest.Create -> create()
            is TerminalRequest.Input -> shells[request.sessionID]?.shell?.let { write(request.sessionID, it, request.dataBytes) }
            is TerminalRequest.Resize -> resize(request)
            is TerminalRequest.Rename -> rename(request)
            is TerminalRequest.Close -> close(request.sessionID)
            else -> Unit
        }
    }

    /** Safe from any thread: the map is concurrent and an entry that already ended is skipped. */
    fun endAll() {
        shells.forEach { (id, entry) -> if (entry.isRunning) ended(id, null) }
    }

    fun closeAll() {
        shells.values.forEach { it.shell?.runCatching { close() } }
        shells.clear()
    }

    private fun create() {
        val id = newId()
        opened++
        val entry = Entry(opened, "Shell $opened",DEFAULT_COLUMNS, DEFAULT_ROWS)
        shells[id] = entry
        // Announced first: the screen drops output for a shell it has not heard of, and the prompt can arrive at once.
        emit(TerminalEvent.Created(info(id, entry)))
        try {
            entry.shell = connection.openShell(
                entry.columns,
                entry.rows,
                onOutput = { emit(TerminalEvent.Output(id, it.toBase64())) },
                onEnd = { status -> ended(id, status) },
            )
        } catch (failure: Exception) {
            shells.remove(id)
            emit(TerminalEvent.Closed(id))
            emit(TerminalEvent.Failed(null, failure.message ?: "The shell could not be opened."))
        }
    }

    private fun ended(id: String, status: Int?) {
        shells[id]?.isRunning = false
        emit(TerminalEvent.Exited(id, status ?: 0))
    }

    private fun write(id: String, shell: SshShell, bytes: ByteArray) {
        try {
            shell.write(bytes)
        } catch (failure: Exception) {
            emit(TerminalEvent.Failed(id, failure.message ?: "The connection ended."))
        }
    }

    private fun resize(request: TerminalRequest.Resize) {
        val entry = shells[request.sessionID] ?: return
        entry.columns = request.columns
        entry.rows = request.rows
        entry.shell?.runCatching { resize(request.columns, request.rows) }
    }

    private fun rename(request: TerminalRequest.Rename) {
        val entry = shells[request.sessionID] ?: return
        entry.name = request.name
        emit(TerminalEvent.Renamed(info(request.sessionID, entry)))
    }

    private fun close(id: String) {
        val entry = shells.remove(id) ?: return
        entry.shell?.runCatching { close() }
        emit(TerminalEvent.Closed(id))
    }

    private fun info(id: String, entry: Entry) =
        TerminalSessionInfo(id, entry.name, entry.isRunning, entry.columns, entry.rows)

    private companion object {
        const val DEFAULT_COLUMNS = 80
        const val DEFAULT_ROWS = 24
    }
}
