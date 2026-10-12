package pl.dmq.peering.session.files

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.yield
import java.io.IOException
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import java.util.UUID

/**
 * The file browser of one Mac, driven by its events and the user's intents. Nothing is sent unless the host declared
 * [supportsFileBrowser]. Download bytes go to [writeDownloadRange] in the order the plan accepts them, so the caller
 * owns the file and its cleanup on failure.
 */
class FileBrowser(
    private val supportsFileBrowser: Boolean,
    private val browserID: String = UUID.randomUUID().toString().uppercase(),
    private val send: (TerminalRequest) -> Unit,
    private val writeDownloadRange: (offset: Long, bytes: ByteArray) -> Unit,
) {
    private val mutableState = MutableStateFlow(FileBrowserState())

    val state: StateFlow<FileBrowserState> = mutableState.asStateFlow()

    /** Opens the scope on the Mac, then lists [initialPath], or the home folder when it is null. */
    fun open(initialPath: String? = null) = whenSupported {
        send(TerminalRequest.StartBrowser(browserID))
        list(initialPath)
    }

    fun list(path: String?) = whenSupported { commit(FileBrowserIntents.list(browserID, mutableState.value, path)) }

    fun openEntry(entry: RemoteDirectoryEntry) =
        whenSupported { commit(FileBrowserIntents.openEntry(browserID, mutableState.value, entry)) }

    fun up() = whenSupported { commit(FileBrowserIntents.up(browserID, mutableState.value)) }

    fun preview(path: String) = whenSupported { commit(FileBrowserIntents.preview(browserID, mutableState.value, path)) }

    fun closePreview() = whenSupported { commit(FileBrowserIntents.closePreview(mutableState.value)) }

    fun download(path: String) = whenSupported {
        commit(FileBrowserIntents.download(browserID, mutableState.value, path, isFolder = false))
    }

    fun downloadFolder(path: String) = whenSupported {
        commit(FileBrowserIntents.download(browserID, mutableState.value, path, isFolder = true))
    }

    fun cancelDownload() = whenSupported { commit(FileBrowserIntents.cancelDownload(mutableState.value)) }

    /** Makes [name] in the folder on screen. A name the computer would refuse is not sent. */
    fun create(name: String, kind: RemoteEntryKind) = changeInFolder {
        if (RemoteFileName.isValid(name)) listOf(RemoteFileOperation.Create(FilePath.child(it, name), kind)) else emptyList()
    }

    fun rename(entry: RemoteDirectoryEntry, to: String) = changeInFolder {
        if (RemoteFileName.isValid(to) && to != entry.name) {
            listOf(RemoteFileOperation.Rename(FilePath.child(it, entry.name), to))
        } else {
            emptyList()
        }
    }

    /** Deletes [entries] one after another; the folder is listed again when the last one is answered. */
    fun delete(entries: List<RemoteDirectoryEntry>) = changeInFolder { folder ->
        entries.map { RemoteFileOperation.Delete(FilePath.child(folder, it.name)) }
    }

    fun dismissFailures() = whenSupported { commit(FileChangeReducer.dismissFailures(mutableState.value)) }

    /**
     * Sends [pieces] as a file called [name] in the folder on screen and returns once the computer has answered or
     * the upload was cancelled. Reading a piece may block, so call it off the main thread.
     */
    suspend fun upload(name: String, totalBytes: Long, pieces: Iterator<ByteArray>) {
        val folder = mutableState.value.listing?.path
        if (!supportsFileBrowser || folder == null || mutableState.value.upload is FileUpload.Running) return
        val path = FilePath.child(folder, name)
        val refusal = when {
            !RemoteFileName.isValid(name) -> UploadFailure.InvalidName
            totalBytes > TransferLimits.MAXIMUM_PHONE_UPLOAD_BYTES -> UploadFailure.TooLarge
            else -> null
        }
        if (refusal != null) return setUpload(FileUpload.Failed(path, refusal))
        setUpload(FileUpload.Running(path, 0, totalBytes))
        try {
            for (request in UploadPlan.requests(browserID, path, totalBytes, counting(path, totalBytes, pieces))) {
                if (mutableState.value.upload !is FileUpload.Running) return
                send(request)
                yield()
            }
        } catch (failure: IOException) {
            return setUpload(FileUpload.Failed(path, UploadFailure.Unreadable))
        }
        mutableState.first { it.upload !is FileUpload.Running }
    }

    /** The phone could not open [name] to send it. */
    fun reportUnreadable(name: String) {
        val folder = mutableState.value.listing?.path ?: return
        setUpload(FileUpload.Failed(FilePath.child(folder, name), UploadFailure.Unreadable))
    }

    fun cancelUpload() {
        if (mutableState.value.upload is FileUpload.Running) setUpload(FileUpload.Idle)
    }

    fun onEvent(event: TerminalEvent) {
        commit(FileBrowserReducer.onEvent(browserID, mutableState.value, event))
    }

    private inline fun changeInFolder(operations: (folder: String) -> List<RemoteFileOperation>) = whenSupported {
        val folder = mutableState.value.listing?.path ?: return@whenSupported
        commit(FileChangeReducer.start(browserID, mutableState.value, operations(folder)))
    }

    private fun setUpload(upload: FileUpload) = mutableState.update { it.copy(upload = upload) }

    private fun counting(path: String, totalBytes: Long, pieces: Iterator<ByteArray>) = object : Iterator<ByteArray> {
        var sent = 0L

        override fun hasNext() = pieces.hasNext()

        override fun next(): ByteArray = pieces.next().also {
            sent += it.size
            mutableState.update { state ->
                if (state.upload is FileUpload.Running) state.copy(upload = FileUpload.Running(path, sent, totalBytes)) else state
            }
        }
    }

    private fun commit(step: FileBrowserStep) {
        mutableState.value = step.state
        if (supportsFileBrowser) step.requests.forEach(send)
        step.piece?.let { writeDownloadRange(it.offset, it.bytes) }
    }

    private inline fun whenSupported(action: () -> Unit) {
        if (supportsFileBrowser) action()
    }
}
