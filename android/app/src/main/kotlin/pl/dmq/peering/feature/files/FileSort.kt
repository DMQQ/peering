package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

enum class FileSort {
    NAME,
    SIZE,
    MODIFIED;

    /** Folders stay above files in every order. Within each group the order is the one named here. */
    fun sorted(entries: List<RemoteDirectoryEntry>): List<RemoteDirectoryEntry> {
        val folders = entries.filter { it.isDirectory }
        val files = entries.filterNot { it.isDirectory }
        return inOrder(folders) + inOrder(files)
    }

    private fun inOrder(entries: List<RemoteDirectoryEntry>): List<RemoteDirectoryEntry> = when (this) {
        NAME -> entries.sortedBy { it.name.lowercase() }
        SIZE -> entries.sortedWith(compareByDescending<RemoteDirectoryEntry> { it.size }.thenBy { it.name.lowercase() })
        MODIFIED -> entries.sortedWith(
            compareByDescending<RemoteDirectoryEntry> { it.modified ?: Double.NEGATIVE_INFINITY }.thenBy { it.name.lowercase() },
        )
    }
}
