package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** Which glyph a row wears: what the entry is, then for a plain file what its extension says it holds. */
enum class FileGlyph {
    FOLDER,
    LINK,
    EXECUTABLE,
    IMAGE,
    CODE,
    ARCHIVE,
    DOCUMENT,
    FILE,
    ;

    companion object {
        fun of(entry: RemoteDirectoryEntry): FileGlyph = when (FileEntryKind.of(entry)) {
            FileEntryKind.FOLDER, FileEntryKind.FOLDER_LINK -> FOLDER
            FileEntryKind.LINK -> LINK
            FileEntryKind.EXECUTABLE -> EXECUTABLE
            FileEntryKind.FILE -> byExtension(entry.name.substringAfterLast('.', "").lowercase())
        }

        private fun byExtension(extension: String): FileGlyph = when (extension) {
            in IMAGES -> IMAGE
            in CODE_FILES -> CODE
            in ARCHIVES -> ARCHIVE
            in DOCUMENTS -> DOCUMENT
            else -> FILE
        }

        private val IMAGES = setOf("png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg")
        private val CODE_FILES = setOf(
            "swift", "kt", "java", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "m",
            "sh", "json", "yaml", "yml", "toml", "html", "css", "xml", "sql",
        )
        private val ARCHIVES = setOf("zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg")
        private val DOCUMENTS = setOf("pdf", "txt", "md", "rtf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx")
    }
}
