package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** What the folder picker shows. [usablePath] is the folder "Use" would choose, null until a listing has arrived. */
data class FolderPickerUi(
    val path: String?,
    val usablePath: String?,
    val parentPath: String?,
    val folders: List<RemoteDirectoryEntry>,
    val isLoading: Boolean,
    val failure: String?,
    val waitingNote: String?,
    val isTruncated: Boolean,
    val query: String,
    val showsHidden: Boolean,
)

/** The picker's raw state; [toUi] turns it into what is drawn. */
internal data class FolderPickerModel(
    val path: String? = null,
    val startPath: String? = null,
    val requestedPath: String? = null,
    val entries: List<RemoteDirectoryEntry> = emptyList(),
    val truncated: Boolean = false,
    val loading: Boolean = false,
    val failure: String? = null,
    val waitingNote: String? = null,
    val query: String = "",
    val showsHidden: Boolean = false,
) {
    fun toUi(): FolderPickerUi {
        val folders = entries
            .filter { it.isDirectory }
            .filter { showsHidden || !it.name.startsWith(".") }
            .filter { query.isEmpty() || it.name.contains(query, ignoreCase = true) }
            .sortedBy { it.name.lowercase() }
        val atStart = path != null && path == startPath
        return FolderPickerUi(
            path = path,
            usablePath = path.takeIf { !loading && failure == null },
            parentPath = if (path == null || atStart) null else FilePath.parent(path),
            folders = folders,
            isLoading = loading,
            failure = failure,
            waitingNote = waitingNote,
            isTruncated = truncated,
            query = query,
            showsHidden = showsHidden,
        )
    }
}
