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

    /** The shell a file can be sent to, or null where the computer has none to offer. */
    val shell: ShellActions? get() = null
}

/** What the file list can do with the computer's shells: put a path on the command line of the one in use, or run a file in a new one. */
interface ShellActions {
    /** True while the shell in use is running, so there is a command line to type on. */
    val ready: StateFlow<Boolean>

    /** Types [path] quoted for the shell, without Return, so the person finishes the line. */
    fun putPath(path: String)

    /** Runs the file at [path] in a new shell. */
    fun run(path: String)
}
