package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.RemoteDirectoryEntry

/**
 * Browses the Mac's folders for a new chat's working directory. [browse] asks the Mac; its answers come back through
 * [onEvent]. Only one listing is outstanding, so any directory answer while loading is the one awaited.
 */
class FolderPicker(
    private val browse: (String?) -> Unit,
    scope: CoroutineScope,
) {
    private val model = MutableStateFlow(FolderPickerModel())

    val ui: StateFlow<FolderPickerUi> = model
        .map { it.toUi() }
        .stateIn(scope, SharingStarted.Eagerly, FolderPickerModel().toUi())

    /** Lists [path], or the Mac's home folder when null. The home folder is the top the picker never climbs above. */
    fun open(path: String? = null) {
        model.update { it.copy(loading = true, failure = null, waitingNote = null, requestedPath = path) }
        browse(path)
    }

    fun enter(entry: RemoteDirectoryEntry) {
        val folder = model.value.path ?: return
        if (entry.isDirectory) open(FilePath.child(folder, entry.name))
    }

    fun up() {
        val parent = ui.value.parentPath ?: return
        open(parent)
    }

    fun setQuery(query: String) = model.update { it.copy(query = query) }

    fun setShowsHidden(showsHidden: Boolean) = model.update { it.copy(showsHidden = showsHidden) }

    fun onEvent(event: AgentEvent) {
        model.update { reduce(it, event) }
    }

    private fun reduce(state: FolderPickerModel, event: AgentEvent): FolderPickerModel = when (event) {
        is AgentEvent.Directory -> if (!state.loading) state else state.copy(
            path = event.path,
            startPath = if (state.requestedPath == null) event.path else state.startPath,
            entries = event.entries,
            truncated = event.truncated,
            loading = false,
            failure = null,
            waitingNote = null,
        )
        is AgentEvent.BrowseFailure -> if (!state.loading) state else state.copy(
            entries = emptyList(),
            truncated = false,
            loading = false,
            failure = event.message,
            waitingNote = null,
        )
        is AgentEvent.BrowseWaiting -> if (!state.loading) state else state.copy(waitingNote = event.message)
        else -> state
    }
}
