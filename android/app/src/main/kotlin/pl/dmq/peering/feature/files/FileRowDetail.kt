package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/**
 * The second line of a row as the iPhone draws it: the mode bits in the terminal face, then " · size · date" in the
 * text face. [mode] is empty and [rest] is a single word when the computer sent no mode, so no numbers are invented.
 */
data class FileRowDetail(val mode: String, val rest: String) {
    /** The words for an entry the computer sent without a mode, in the app's language. */
    data class KindWords(val symlink: String, val folder: String, val file: String)

    companion object {
        private const val SEPARATOR = " · "

        fun of(entry: RemoteDirectoryEntry, modifiedLabel: String?, words: KindWords): FileRowDetail {
            if (entry.permissions.isEmpty()) {
                val word = when {
                    entry.isSymlink -> words.symlink
                    entry.isDirectory -> words.folder
                    else -> words.file
                }
                return FileRowDetail("", word)
            }
            val parts = listOfNotNull(
                if (entry.isSymlink) words.symlink else fileSizeLabel(entry.size),
                modifiedLabel,
            )
            return FileRowDetail(entry.permissions, SEPARATOR + parts.joinToString(SEPARATOR))
        }
    }
}
