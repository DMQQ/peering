package pl.dmq.peering.feature.files

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind

/**
 * What the file screens ask of one computer's browser. The session controller implements it over `FileBrowser`, which
 * owns the requests, the download bytes and the state.
 */
interface FileBrowsingPort {
    val state: StateFlow<FileBrowserState>

    /** False while the link to the computer is down; requests made then are dropped. */
    val online: StateFlow<Boolean>

    fun open(initialPath: String?)

    fun list(path: String?)

    fun openEntry(entry: RemoteDirectoryEntry)

    fun up()

    fun preview(path: String)

    fun closePreview()

    /**
     * Downloads [path] into [destination], the document the user picked, which the caller has already created. A
     * folder is zipped on the computer first.
     */
    fun download(path: String, destination: String, isFolder: Boolean = false)

    fun cancelDownload()

    /** True once the chosen destination could not be opened or written. */
    val destinationFailed: StateFlow<Boolean>

    fun create(name: String, kind: RemoteEntryKind)

    fun rename(entry: RemoteDirectoryEntry, to: String)

    fun delete(entries: List<RemoteDirectoryEntry>)

    fun dismissFailures()

    /** Sends each document, named by [sources] as content addresses, into the folder on screen, one after another. */
    fun upload(sources: List<String>)

    fun cancelUpload()
}
