package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest

/** Folds the computer's answers to creates, renames, deletes and uploads into the browser, then refreshes the folder. */
internal object FileChangeReducer {
    fun start(browserID: String, state: FileBrowserState, operations: List<RemoteFileOperation>): FileBrowserStep {
        if (operations.isEmpty() || state.changes.isRunning) return FileBrowserStep(state)
        return FileBrowserStep(
            state.copy(changes = FileChanges(queue = operations)),
            listOf(TerminalRequest.ChangeFile(browserID, operations.first())),
        )
    }

    fun dismissFailures(state: FileBrowserState): FileBrowserStep {
        val upload = if (state.upload is FileUpload.Failed || state.upload is FileUpload.Done) FileUpload.Idle else state.upload
        return FileBrowserStep(state.copy(changes = state.changes.copy(failure = null), upload = upload))
    }

    fun done(browserID: String, state: FileBrowserState, event: TerminalEvent.FileOperationDone): FileBrowserStep {
        val head = state.changes.inFlight ?: return FileBrowserStep(state)
        if (FileChanges.pathOf(head) != event.path) return FileBrowserStep(state)
        val rest = state.changes.queue.drop(1)
        if (rest.isNotEmpty()) {
            return FileBrowserStep(
                state.copy(changes = FileChanges(queue = rest)),
                listOf(TerminalRequest.ChangeFile(browserID, rest.first())),
            )
        }
        return refreshed(browserID, state.copy(changes = FileChanges()))
    }

    fun failed(browserID: String, state: FileBrowserState, event: TerminalEvent.FileOperationFailure): FileBrowserStep {
        val head = state.changes.inFlight ?: return FileBrowserStep(state)
        if (FileChanges.pathOf(head) != event.path) return FileBrowserStep(state)
        return refreshed(browserID, state.copy(changes = FileChanges(failure = event.message)))
    }

    fun uploadEvent(browserID: String, state: FileBrowserState, event: TerminalEvent): FileBrowserStep {
        val running = state.upload as? FileUpload.Running ?: return FileBrowserStep(state)
        val outcome = UploadPlan.outcome(event)?.takeIf { it.path == running.path } ?: return FileBrowserStep(state)
        return when (outcome) {
            is UploadOutcome.Written -> refreshed(browserID, state.copy(upload = FileUpload.Done(running.path)))
            is UploadOutcome.Failed ->
                FileBrowserStep(state.copy(upload = FileUpload.Failed(running.path, UploadFailure.Host(outcome.message))))
        }
    }

    private fun refreshed(browserID: String, state: FileBrowserState): FileBrowserStep {
        val folder = state.listing?.path ?: return FileBrowserStep(state)
        return FileBrowserIntents.list(browserID, state, folder)
    }
}
