package pl.dmq.peering.feature.files

import pl.dmq.peering.session.files.FilePath

/** The media type a share sheet is told a file has, from its name. Anything unrecognised is plain bytes. */
object MimeTypes {
    private val known = mapOf(
        "png" to "image/png",
        "jpg" to "image/jpeg",
        "jpeg" to "image/jpeg",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "heic" to "image/heic",
        "svg" to "image/svg+xml",
        "pdf" to "application/pdf",
        "json" to "application/json",
        "zip" to "application/zip",
        "md" to "text/markdown",
        "html" to "text/html",
        "csv" to "text/csv",
        "xml" to "text/xml",
    )

    fun of(path: String): String {
        val extension = FileGlyph.extensionOf(FilePath.name(path))
        known[extension]?.let { return it }
        return when (FileGlyph.byName(FilePath.name(path))) {
            FileGlyph.CODE, FileGlyph.TEXT -> "text/plain"
            FileGlyph.IMAGE -> "image/*"
            FileGlyph.VIDEO -> "video/*"
            FileGlyph.AUDIO -> "audio/*"
            else -> "application/octet-stream"
        }
    }
}
