package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/**
 * The second line of a row as the iPhone draws it: the mode bits in the terminal face, then " · size · date" in the
 * text face. [mode] is empty and [rest] is a single word when the computer sent no mode, so no numbers are invented.
 */
data class FileRowDetail(val mode: String, val rest: String) {
    companion object {
        private const val SEPARATOR = " · "

        fun of(entry: RemoteDirectoryEntry, modifiedLabel: String?): FileRowDetail {
            if (entry.permissions.isEmpty()) {
                val word = when {
                    entry.isSymlink -> "Symbolic link"
                    entry.isDirectory -> "Folder"
                    else -> "File"
                }
                return FileRowDetail("", word)
            }
            val parts = listOfNotNull(
                if (entry.isSymlink) "Symbolic link" else fileSizeLabel(entry.size),
                modifiedLabel,
            )
            return FileRowDetail(entry.permissions, SEPARATOR + parts.joinToString(SEPARATOR))
        }
    }
}
