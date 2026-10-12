package pl.dmq.peering.feature.files

import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.wire.RemoteDirectoryEntry

enum class FileListStatus {
    LOADING,
    ERROR,
    EMPTY,
    CONTENT,
}

/** What the file list shows. [isRefreshing] is set while a new folder is being listed over the old one. */
data class FileListUi(
    val status: FileListStatus,
    val path: String?,
    val breadcrumbs: List<FilePath.Breadcrumb>,
    val entries: List<RemoteDirectoryEntry>,
    val failure: String?,
    val isTruncated: Boolean,
    val isRefreshing: Boolean,
    val canGoUp: Boolean,
    val sort: FileSort,
    val showsHidden: Boolean,
)
