package pl.dmq.peering.session.files

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.RemoteDirectoryEntry
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
    private val browserID: String = UUID.randomUUID().toString(),
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

    fun onEvent(event: TerminalEvent) {
        commit(FileBrowserReducer.onEvent(browserID, mutableState.value, event))
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
