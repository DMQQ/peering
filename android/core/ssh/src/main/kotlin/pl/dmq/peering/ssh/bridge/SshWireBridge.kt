package pl.dmq.peering.ssh.bridge

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest

/**
 * One server's connection, spoken to in the terminal and file screens' own requests and events. Shell requests and
 * file requests each have a worker, so a slow folder listing never holds up a keystroke, and each worker keeps the
 * order its requests came in.
 */
class SshWireBridge(
    connection: SshConnection,
    scope: CoroutineScope,
    dispatcher: CoroutineDispatcher,
    private val emit: (TerminalEvent) -> Unit,
) {
    private val shells = SshShellBridge(connection, emit)
    private val files = SshFilesBridge(connection::sftp, emit)
    private val shellRequests = Channel<TerminalRequest>(Channel.UNLIMITED)
    private val fileRequests = Channel<TerminalRequest>(Channel.UNLIMITED)

    init {
        scope.launch(dispatcher) { for (request in shellRequests) guarded { shells.handle(request) } }
        scope.launch(dispatcher) { for (request in fileRequests) guarded { files.handle(request) } }
    }

    fun send(request: TerminalRequest) {
        when (request) {
            is TerminalRequest.ListDirectory, is TerminalRequest.ReadFile, is TerminalRequest.ReadRange,
            is TerminalRequest.ArchiveFolder, is TerminalRequest.BeginWrite, is TerminalRequest.WriteChunk,
            is TerminalRequest.ChangeFile,
            -> fileRequests.trySend(request)
            is TerminalRequest.StartBrowser -> Unit
            else -> shellRequests.trySend(request)
        }
    }

    /** The link is gone: every shell that was running has ended. */
    fun connectionLost() {
        shells.endAll()
    }

    fun close() {
        shellRequests.close()
        fileRequests.close()
        shells.closeAll()
        files.close()
    }

    private inline fun guarded(action: () -> Unit) {
        try {
            action()
        } catch (failure: Exception) {
            emit(TerminalEvent.Failed(null, failure.message ?: "The connection ended."))
        }
    }
}
