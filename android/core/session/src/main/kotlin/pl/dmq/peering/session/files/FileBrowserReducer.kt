package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.TerminalEvent

/** Folds one Mac event into the browser. Events for another scope, or for no scope, leave the state as it is. */
internal object FileBrowserReducer {
    fun onEvent(browserID: String, state: FileBrowserState, event: TerminalEvent): FileBrowserStep {
        // The Mac echoes the id in uppercase, as Swift writes a UUID, so the match ignores case.
        if (sessionOf(event)?.equals(browserID, ignoreCase = true) != true) return FileBrowserStep(state)
        return when (event) {
            is TerminalEvent.Directory -> directory(state, event.path, event.entries, event.truncated)
            is TerminalEvent.BrowseFailure -> browseFailure(state, event.path, event.message)
            is TerminalEvent.FileContents -> fileContents(state, event)
            is TerminalEvent.FileRange -> fileRange(state, event)
            is TerminalEvent.ArchiveReady -> archiveReady(state, event)
            is TerminalEvent.TransferFailure -> transferFailure(state, event)
            is TerminalEvent.FileOperationDone -> FileChangeReducer.done(browserID, state, event)
            is TerminalEvent.FileOperationFailure -> FileChangeReducer.failed(browserID, state, event)
            is TerminalEvent.WroteFile, is TerminalEvent.WriteFailure -> FileChangeReducer.uploadEvent(browserID, state, event)
            is TerminalEvent.Failed -> FileBrowserStep(state.copy(browseFailure = event.message, listingLoading = false))
            else -> FileBrowserStep(state)
        }
    }

    private fun sessionOf(event: TerminalEvent): String? = when (event) {
        is TerminalEvent.Directory -> event.sessionID
        is TerminalEvent.BrowseFailure -> event.sessionID
        is TerminalEvent.FileContents -> event.sessionID
        is TerminalEvent.FileRange -> event.sessionID
        is TerminalEvent.ArchiveReady -> event.sessionID
        is TerminalEvent.TransferFailure -> event.sessionID
        is TerminalEvent.FileOperationDone -> event.sessionID
        is TerminalEvent.FileOperationFailure -> event.sessionID
        is TerminalEvent.WroteFile -> event.sessionID
        is TerminalEvent.WriteFailure -> event.sessionID
        is TerminalEvent.Failed -> event.sessionID
        else -> null
    }

    private fun directory(
        state: FileBrowserState,
        path: String,
        entries: List<RemoteDirectoryEntry>,
        truncated: Boolean,
    ): FileBrowserStep = FileBrowserStep(
        state.copy(listing = DirectoryModel(path, entries, truncated), listingLoading = false, browseFailure = null),
    )

    /** The Mac answers a read of a file with a failure naming that file, so a failure naming the open preview belongs to it. */
    private fun browseFailure(state: FileBrowserState, path: String, message: String): FileBrowserStep {
        val preview = state.preview
        if (preview != null && preview.isLoading && preview.path == path) {
            return FileBrowserStep(state.copy(preview = preview.copy(failure = message)))
        }
        return FileBrowserStep(state.copy(listing = null, listingLoading = false, browseFailure = message))
    }

    /** A piece is kept only when it continues the bytes held and stays under the cap for its kind. */
    private fun fileContents(state: FileBrowserState, event: TerminalEvent.FileContents): FileBrowserStep {
        val preview = state.preview?.takeIf { it.path == event.path && it.isLoading } ?: return FileBrowserStep(state)
        val piece = event.dataBytes
        val fits = event.offset == preview.contents.size.toLong() &&
            preview.contents.size + piece.size <= FilePreview.byteLimit(event.kind)
        val contents = if (fits) preview.contents + piece else preview.contents
        val updated = preview.copy(
            kind = event.kind,
            contents = contents,
            totalBytes = event.totalBytes,
            isComplete = event.isLast,
        )
        return FileBrowserStep(state.copy(preview = updated))
    }

    private fun fileRange(state: FileBrowserState, event: TerminalEvent.FileRange): FileBrowserStep {
        val running = state.transfer as? FileTransfer.Running ?: return FileBrowserStep(state)
        val piece = event.dataBytes
        return when (val step = running.plan.onFileRange(event.path, event.offset, event.totalBytes, piece.size)) {
            is DownloadStep.Continue -> FileBrowserStep(
                state.copy(transfer = FileTransfer.Running(step.plan)),
                step.requests,
                DownloadPiece(event.offset, piece),
            )
            is DownloadStep.Complete -> FileBrowserStep(
                state.copy(transfer = FileTransfer.Finished(step.plan.sourcePath)),
                piece = DownloadPiece(event.offset, piece),
            )
            is DownloadStep.Failed -> FileBrowserStep(
                state.copy(transfer = FileTransfer.Failed(running.plan.sourcePath, step.reason)),
            )
            DownloadStep.Ignored -> FileBrowserStep(state)
        }
    }

    private fun archiveReady(state: FileBrowserState, event: TerminalEvent.ArchiveReady): FileBrowserStep {
        val running = state.transfer as? FileTransfer.Running ?: return FileBrowserStep(state)
        val step = running.plan.onArchiveReady(event.folder, event.archivePath) as? DownloadStep.Continue
            ?: return FileBrowserStep(state)
        return FileBrowserStep(state.copy(transfer = FileTransfer.Running(step.plan)), step.requests)
    }

    private fun transferFailure(state: FileBrowserState, event: TerminalEvent.TransferFailure): FileBrowserStep {
        val running = state.transfer as? FileTransfer.Running ?: return FileBrowserStep(state)
        val step = running.plan.onTransferFailure(event.path, event.message) as? DownloadStep.Failed
            ?: return FileBrowserStep(state)
        return FileBrowserStep(state.copy(transfer = FileTransfer.Failed(running.plan.sourcePath, step.reason)))
    }
}
