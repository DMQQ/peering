package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** Which icon a row wears: what the entry is first, then what its name says the file holds. */
enum class FileGlyph {
    FOLDER,
    FOLDER_LINK,
    LINK,
    EXECUTABLE,
    IMAGE,
    VIDEO,
    AUDIO,
    PDF,
    ARCHIVE,
    MARKDOWN,
    CODE,
    TEXT,
    GENERIC,
    ;

    companion object {
        private val images = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "avif")
        private val videos = setOf("mp4", "mov", "m4v", "mkv", "avi", "webm")
        private val audio = setOf("mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff")
        private val archives = setOf("zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg")
        private val markdown = setOf("md", "markdown")
        private val text = setOf("txt", "log", "rtf", "csv", "tsv", "json", "yaml", "yml", "toml", "ini", "xml", "plist", "env")
        private val code = setOf(
            "swift", "kt", "kts", "java", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cc", "cpp", "hpp",
            "m", "mm", "cs", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss", "gradle", "lua", "dart",
        )

        fun of(entry: RemoteDirectoryEntry): FileGlyph = when (FileEntryKind.of(entry)) {
            FileEntryKind.FOLDER -> FOLDER
            FileEntryKind.FOLDER_LINK -> FOLDER_LINK
            FileEntryKind.LINK -> LINK
            FileEntryKind.EXECUTABLE -> EXECUTABLE
            FileEntryKind.FILE -> byExtension(extensionOf(entry.name))
        }

        fun byName(name: String): FileGlyph = byExtension(extensionOf(name))

        /** Lowercased, without the dot; empty for no extension or a dotfile such as `.env`. */
        fun extensionOf(name: String): String =
            if (name.lastIndexOf('.') > 0) name.substringAfterLast('.').lowercase() else ""

        private fun byExtension(extension: String): FileGlyph = when (extension) {
            in images -> IMAGE
            in videos -> VIDEO
            in audio -> AUDIO
            "pdf" -> PDF
            in archives -> ARCHIVE
            in markdown -> MARKDOWN
            in code -> CODE
            in text -> TEXT
            else -> GENERIC
        }
    }
}
