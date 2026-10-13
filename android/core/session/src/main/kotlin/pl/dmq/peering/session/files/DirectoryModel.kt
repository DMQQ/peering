package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** One folder as the browser shows it: what the Mac listed, with the hidden-file choice applied when read. */
data class DirectoryModel(
    val path: String,
    val entries: List<RemoteDirectoryEntry>,
    val isTruncated: Boolean,
    val showHidden: Boolean = false,
) {
    /** Folders first, then names compared without case; dotfiles are left out unless [showHidden]. */
    val visibleEntries: List<RemoteDirectoryEntry>
        get() = entries
            .filter { showHidden || !it.name.startsWith('.') }
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))

    val breadcrumbs: List<FilePath.Breadcrumb> get() = FilePath.breadcrumbs(path)

    val parentPath: String? get() = FilePath.parent(path)
}
