package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteFileOperation

/**
 * The create, rename and delete operations the browser has asked the computer for. [queue] is sent one at a time:
 * the computer echoes the path it was given, so the head is the only operation in flight. [failure] is the
 * computer's own text for the operation that stopped the run.
 */
data class FileChanges(
    val queue: List<RemoteFileOperation> = emptyList(),
    val failure: String? = null,
) {
    val isRunning: Boolean get() = queue.isNotEmpty()

    val inFlight: RemoteFileOperation? get() = queue.firstOrNull()

    companion object {
        fun pathOf(operation: RemoteFileOperation): String = when (operation) {
            is RemoteFileOperation.Create -> operation.path
            is RemoteFileOperation.Rename -> operation.path
            is RemoteFileOperation.Delete -> operation.path
        }
    }
}
