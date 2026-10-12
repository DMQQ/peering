package pl.dmq.peering.feature.files

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.files.FilePath

/** A download waiting for the user to pick where it goes. [suggestedName] gets `.zip` for a folder. */
data class DestinationRequest(val path: String, val suggestedName: String, val isFolder: Boolean)

/**
 * Download asks for a destination first: the screen opens the system's save dialog for [request] and reports the
 * document back through [chosen], and only then does the download start.
 */
class DownloadDestination(private val port: FileBrowsingPort) {
    private val pending = MutableStateFlow<DestinationRequest?>(null)

    val request: StateFlow<DestinationRequest?> = pending.asStateFlow()

    fun ask(path: String, isFolder: Boolean) {
        val name = FilePath.name(path)
        pending.value = DestinationRequest(path, if (isFolder) "$name.zip" else name, isFolder)
    }

    /** The document the user picked, or null when they backed out of the dialog. */
    fun chosen(uri: String?) {
        val asked = pending.value ?: return
        pending.value = null
        if (uri != null) port.download(asked.path, uri, asked.isFolder)
    }
}
