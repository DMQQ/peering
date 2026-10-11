package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.TerminalRequest

/** What the user asks for in the browser. Each returns the next state and the requests that go to the Mac. */
internal object FileBrowserIntents {
    /** A null [path] asks for the Mac's home folder. The listing keeps its old contents until the answer replaces them. */
    fun list(browserID: String, state: FileBrowserState, path: String?): FileBrowserStep = FileBrowserStep(
        state.copy(listingLoading = true, browseFailure = null),
        listOf(TerminalRequest.ListDirectory(browserID, path)),
    )

    fun openEntry(browserID: String, state: FileBrowserState, entry: RemoteDirectoryEntry): FileBrowserStep {
        val folder = state.listing?.path ?: return FileBrowserStep(state)
        val target = FilePath.child(folder, entry.name)
        return if (entry.isDirectory) list(browserID, state, target) else preview(browserID, state, target)
    }

    fun up(browserID: String, state: FileBrowserState): FileBrowserStep {
        val parent = state.listing?.parentPath ?: return FileBrowserStep(state)
        return list(browserID, state, parent)
    }

    fun preview(browserID: String, state: FileBrowserState, path: String): FileBrowserStep = FileBrowserStep(
        state.copy(preview = FilePreview(path)),
        listOf(TerminalRequest.ReadFile(browserID, path)),
    )

    fun closePreview(state: FileBrowserState): FileBrowserStep = FileBrowserStep(state.copy(preview = null))

    /** A folder is zipped on the Mac first; the zip is then read like a file. Starting replaces any running download. */
    fun download(browserID: String, state: FileBrowserState, path: String, isFolder: Boolean): FileBrowserStep {
        val plan = FileDownloadPlan(
            sessionID = browserID,
            sourcePath = path,
            isFolder = isFolder,
            readPath = if (isFolder) null else path,
        )
        val (started, request) = plan.start()
        return FileBrowserStep(state.copy(transfer = FileTransfer.Running(started)), listOf(request))
    }

    fun cancelDownload(state: FileBrowserState): FileBrowserStep = FileBrowserStep(state.copy(transfer = FileTransfer.Idle))
}
