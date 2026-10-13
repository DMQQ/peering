package pl.dmq.peering.ssh.bridge

import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.session.files.TransferLimits
import pl.dmq.peering.ssh.transport.SftpClient
import pl.dmq.peering.ssh.transport.SftpUpload
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.toBase64

/**
 * Answers the file browser's requests from an SFTP channel, in the events it already understands, so the folder list,
 * preview, download and upload screens written for a computer serve a server too. [open] makes the channel on first use.
 */
internal class SshFilesBridge(private val open: () -> SftpClient, private val emit: (TerminalEvent) -> Unit) {
    private var client: SftpClient? = null
    private var upload: SftpUpload? = null
    private var uploadPath: String? = null

    fun handle(request: TerminalRequest) {
        when (request) {
            is TerminalRequest.ListDirectory -> answering(request.sessionID, request.path ?: "") {
                emit(directory(request.sessionID, request.path))
            }
            is TerminalRequest.ReadFile -> answering(request.sessionID, request.path) { preview(request) }
            is TerminalRequest.ReadRange -> transferring(request)
            is TerminalRequest.ArchiveFolder -> emit(
                TerminalEvent.TransferFailure(request.sessionID, request.path, FOLDER_DOWNLOAD_UNSUPPORTED),
            )
            is TerminalRequest.BeginWrite -> beginWrite(request)
            is TerminalRequest.WriteChunk -> writeChunk(request)
            is TerminalRequest.ChangeFile -> change(request)
            else -> Unit
        }
    }

    fun close() {
        upload?.runCatching { close() }
        client?.runCatching { close() }
        upload = null
        client = null
    }

    private fun sftp(): SftpClient = client ?: open().also { client = it }

    private fun directory(sessionID: String, path: String?): TerminalEvent {
        val listing = sftp().list(path)
        val sorted = listing.entries.sortedWith(compareByDescending<RemoteDirectoryEntry> { it.isDirectory }.thenBy { it.name.lowercase() })
        val kept = sorted.take(MAXIMUM_ENTRIES)
        return TerminalEvent.Directory(sessionID, listing.path, kept, truncated = sorted.size > kept.size)
    }

    private fun preview(request: TerminalRequest.ReadFile) {
        val extensionKind = kindByName(request.path)
        var offset = 0L
        while (true) {
            val piece = sftp().read(request.path, offset, PREVIEW_PIECE_BYTES)
            val kind = extensionKind ?: if (looksBinary(piece.bytes)) null else RemoteFileKind.TEXT
            if (kind == null) {
                emit(TerminalEvent.BrowseFailure(request.sessionID, request.path, NOT_PREVIEWABLE))
                return
            }
            offset += piece.bytes.size
            val limit = FilePreview.byteLimit(kind)
            val last = piece.bytes.isEmpty() || offset >= piece.totalBytes || offset >= limit
            emit(TerminalEvent.FileContents(request.sessionID, request.path, kind, offset - piece.bytes.size, piece.totalBytes, piece.bytes.toBase64(), last))
            if (last) return
        }
    }

    private fun transferring(request: TerminalRequest.ReadRange) {
        try {
            val piece = sftp().read(request.path, request.offset, TransferLimits.DOWNLOAD_CHUNK_BYTES)
            emit(TerminalEvent.FileRange(request.sessionID, request.path, request.offset, piece.totalBytes, piece.bytes.toBase64()))
        } catch (failure: Exception) {
            emit(TerminalEvent.TransferFailure(request.sessionID, request.path, reason(failure)))
        }
    }

    private fun beginWrite(request: TerminalRequest.BeginWrite) {
        upload?.runCatching { close() }
        try {
            upload = sftp().beginWrite(request.path)
            uploadPath = request.path
        } catch (failure: Exception) {
            upload = null
            emit(TerminalEvent.WriteFailure(request.sessionID, request.path, reason(failure)))
        }
    }

    private fun writeChunk(request: TerminalRequest.WriteChunk) {
        val sink = upload?.takeIf { uploadPath == request.path } ?: return
        try {
            sink.write(request.dataBytes)
            if (!request.isLast) return
            val size = sink.finish()
            upload = null
            emit(TerminalEvent.WroteFile(request.sessionID, request.path, size))
        } catch (failure: Exception) {
            upload = null
            sink.runCatching { close() }
            emit(TerminalEvent.WriteFailure(request.sessionID, request.path, reason(failure)))
        }
    }

    private fun change(request: TerminalRequest.ChangeFile) {
        val operation = request.operation
        val path = when (operation) {
            is RemoteFileOperation.Create -> operation.path
            is RemoteFileOperation.Rename -> operation.path
            is RemoteFileOperation.Delete -> operation.path
        }
        try {
            emit(TerminalEvent.FileOperationDone(request.sessionID, path, perform(operation)))
        } catch (failure: Exception) {
            emit(TerminalEvent.FileOperationFailure(request.sessionID, path, reason(failure)))
        }
    }

    /** The note a delete composes (how much went with a folder), or empty. */
    private fun perform(operation: RemoteFileOperation): String {
        when (operation) {
            is RemoteFileOperation.Create ->
                if (operation.kind == RemoteEntryKind.FOLDER) sftp().createFolder(operation.path) else sftp().createFile(operation.path)
            is RemoteFileOperation.Rename -> sftp().rename(operation.path, operation.to)
            is RemoteFileOperation.Delete -> return sftp().delete(operation.path)
        }
        return ""
    }

    private inline fun answering(sessionID: String, path: String, action: () -> Unit) {
        try {
            action()
        } catch (failure: Exception) {
            emit(TerminalEvent.BrowseFailure(sessionID, path, reason(failure)))
        }
    }

    private fun reason(failure: Exception): String =
        (failure as? SshFailure.Browse)?.reason ?: failure.message ?: NO_ANSWER

    private companion object {
        const val MAXIMUM_ENTRIES = 5_000
        const val PREVIEW_PIECE_BYTES = 64 * 1024
        const val NO_ANSWER = "The server did not answer."
        const val NOT_PREVIEWABLE = "This file is not text, so it cannot be shown here. Download it instead."
        const val FOLDER_DOWNLOAD_UNSUPPORTED = "A folder cannot be downloaded over SFTP. Download its files one by one."

        val IMAGES = setOf("png", "jpg", "jpeg", "gif", "webp", "bmp", "heic")

        fun kindByName(path: String): RemoteFileKind? {
            val extension = path.substringAfterLast('.', "").lowercase()
            return when {
                extension in IMAGES -> RemoteFileKind.IMAGE
                extension == "svg" -> RemoteFileKind.SVG
                else -> null
            }
        }

        fun looksBinary(bytes: ByteArray): Boolean = bytes.take(SNIFF_BYTES).any { it == 0.toByte() }

        const val SNIFF_BYTES = 8 * 1024
    }
}
