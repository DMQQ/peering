package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.toBase64

/** A Mac that answers file requests from a fixed set of folders and files, the way the host does for a healthy path. */
class ScriptedFileHost(
    private val home: String = "/Users/me",
    private val folders: Map<String, List<RemoteDirectoryEntry>>,
    private val files: Map<String, ByteArray> = emptyMap(),
    private val archives: Map<String, String> = emptyMap(),
) {
    fun answer(request: TerminalRequest): List<TerminalEvent> = when (request) {
        is TerminalRequest.ListDirectory -> listDirectory(request)
        is TerminalRequest.ReadFile -> readFile(request)
        is TerminalRequest.ReadRange -> readRange(request)
        is TerminalRequest.ArchiveFolder -> archiveFolder(request)
        is TerminalRequest.ChangeFile -> changeFile(request)
        is TerminalRequest.WriteChunk -> writeChunk(request)
        else -> emptyList()
    }

    /** Paths the host refuses to change or write, with the text it answers. */
    val refusals = mutableMapOf<String, String>()
    private val received = mutableMapOf<String, ByteArray>()

    private fun changeFile(request: TerminalRequest.ChangeFile): List<TerminalEvent> {
        val path = when (val operation = request.operation) {
            is RemoteFileOperation.Create -> operation.path
            is RemoteFileOperation.Rename -> operation.path
            is RemoteFileOperation.Delete -> operation.path
        }
        val refusal = refusals[path]
            ?: return listOf(TerminalEvent.FileOperationDone(request.sessionID, path, ""))
        return listOf(TerminalEvent.FileOperationFailure(request.sessionID, path, refusal))
    }

    private fun writeChunk(request: TerminalRequest.WriteChunk): List<TerminalEvent> {
        received[request.path] = (received[request.path] ?: ByteArray(0)) + request.dataBytes
        if (!request.isLast) return emptyList()
        refusals[request.path]?.let { return listOf(TerminalEvent.WriteFailure(request.sessionID, request.path, it)) }
        return listOf(TerminalEvent.WroteFile(request.sessionID, request.path, received.getValue(request.path).size.toLong()))
    }

    private fun listDirectory(request: TerminalRequest.ListDirectory): List<TerminalEvent> {
        val path = request.path ?: home
        val entries = folders[path] ?: return listOf(TerminalEvent.BrowseFailure(request.sessionID, path, "No such folder"))
        return listOf(TerminalEvent.Directory(request.sessionID, path, entries, truncated = false))
    }

    private fun readFile(request: TerminalRequest.ReadFile): List<TerminalEvent> {
        val bytes = files[request.path]
            ?: return listOf(TerminalEvent.BrowseFailure(request.sessionID, request.path, "Cannot read that file"))
        return listOf(
            TerminalEvent.FileContents(
                sessionID = request.sessionID,
                path = request.path,
                kind = RemoteFileKind.TEXT,
                offset = 0,
                totalBytes = bytes.size.toLong(),
                data = bytes.toBase64(),
                isLast = true,
            ),
        )
    }

    private fun readRange(request: TerminalRequest.ReadRange): List<TerminalEvent> {
        val bytes = files[request.path]
            ?: return listOf(TerminalEvent.TransferFailure(request.sessionID, request.path, "Cannot read that file"))
        val start = request.offset.toInt()
        val end = minOf(bytes.size, start + CHUNK_BYTES)
        val piece = bytes.copyOfRange(start, end)
        return listOf(
            TerminalEvent.FileRange(
                sessionID = request.sessionID,
                path = request.path,
                offset = request.offset,
                totalBytes = bytes.size.toLong(),
                data = piece.toBase64(),
            ),
        )
    }

    private fun archiveFolder(request: TerminalRequest.ArchiveFolder): List<TerminalEvent> {
        val archivePath = archives[request.path]
            ?: return listOf(TerminalEvent.TransferFailure(request.sessionID, request.path, "Cannot zip that folder"))
        val size = files.getValue(archivePath).size.toLong()
        return listOf(TerminalEvent.ArchiveReady(request.sessionID, request.path, archivePath, size))
    }

    companion object {
        /** Matches the download piece size the phone asks for, so the scripted pieces line up with the window. */
        const val CHUNK_BYTES = TransferLimits.DOWNLOAD_CHUNK_BYTES
    }
}
