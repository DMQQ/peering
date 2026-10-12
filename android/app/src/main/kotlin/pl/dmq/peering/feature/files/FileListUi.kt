package pl.dmq.peering.feature.files

import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.session.files.FileUpload
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind

enum class FileListStatus {
    LOADING,
    ERROR,
    OFFLINE,
    EMPTY,
    NO_MATCH,
    CONTENT,
}

/** One row of the folder. [modifiedEpochMillis] is null when the computer sent no date. */
data class FileRowUi(
    val entry: RemoteDirectoryEntry,
    val glyph: FileGlyph,
    val isSelected: Boolean,
) {
    val name: String get() = entry.name
    val isFolder: Boolean get() = entry.isDirectory
    val modifiedEpochMillis: Long? get() = entry.modified?.let { (it * MILLIS + APPLE_EPOCH_MILLIS).toLong() }

    private companion object {
        const val MILLIS = 1000.0

        /** The wire counts seconds from 2001-01-01. */
        const val APPLE_EPOCH_MILLIS = 978_307_200_000L
    }
}

/** A dialog over the list. */
sealed interface FileDialog {
    enum class Purpose { NEW_FOLDER, NEW_FILE, RENAME }

    enum class NameProblem { INVALID, TAKEN }

    data class Name(
        val purpose: Purpose,
        val text: String,
        val target: RemoteDirectoryEntry? = null,
        val problem: NameProblem? = null,
    ) : FileDialog {
        val kind: RemoteEntryKind get() = if (purpose == Purpose.NEW_FILE) RemoteEntryKind.FILE else RemoteEntryKind.FOLDER
    }

    data class ConfirmDelete(val entries: List<RemoteDirectoryEntry>) : FileDialog {
        val includesFolder: Boolean get() = entries.any { it.isDirectory }
    }
}

/** What the file list shows. [isRefreshing] is set while a new folder is being listed over the old one. */
data class FileListUi(
    val status: FileListStatus,
    val path: String?,
    val breadcrumbs: List<FilePath.Breadcrumb>,
    val entries: List<FileRowUi>,
    val failure: String?,
    val failureKind: FileFailureKind,
    val isTruncated: Boolean,
    val isRefreshing: Boolean,
    val canGoUp: Boolean,
    val sort: FileSort,
    val showsHidden: Boolean,
    val query: String,
    val selectedCount: Int,
    val dialog: FileDialog?,
    val changeFailure: String?,
    val isChanging: Boolean,
    val isOffline: Boolean,
    val upload: FileUpload,
    val download: DownloadStatus,
) {
    val isSelecting: Boolean get() = selectedCount > 0

    /** New entries, renames and deletes wait for a folder, a live link and the last change's answer. */
    val canChange: Boolean get() = path != null && !isOffline && !isChanging && upload !is FileUpload.Running
}
