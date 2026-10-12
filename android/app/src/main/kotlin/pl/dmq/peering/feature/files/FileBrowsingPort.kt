package pl.dmq.peering.feature.files

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry

/**
 * What the file screens ask of one Mac's browser. The session controller implements it over `FileBrowser`, which
 * owns the requests, the download bytes and the state.
 */
interface FileBrowsingPort {
    val state: StateFlow<FileBrowserState>

    fun open(initialPath: String?)

    fun list(path: String?)

    fun openEntry(entry: RemoteDirectoryEntry)

    fun up()

    fun preview(path: String)

    fun closePreview()

    fun download(path: String)

    fun downloadFolder(path: String)

    fun cancelDownload()
}
