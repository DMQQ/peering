package pl.dmq.peering.feature.files

import pl.dmq.peering.session.files.FilePath

/** Where a picture or a video lands in the phone's gallery, and the media type the gallery files it under. */
data class GalleryTarget(val displayName: String, val mimeType: String, val isVideo: Boolean) {
    val relativePath: String get() = if (isVideo) "Movies/Peering" else "Pictures/Peering"

    companion object {
        private val imageTypes = mapOf(
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "gif" to "image/gif",
            "webp" to "image/webp",
            "heic" to "image/heic",
            "heif" to "image/heif",
            "bmp" to "image/bmp",
            "avif" to "image/avif",
        )
        private val videoTypes = mapOf(
            "mp4" to "video/mp4",
            "m4v" to "video/x-m4v",
            "mov" to "video/quicktime",
            "webm" to "video/webm",
            "mkv" to "video/x-matroska",
            "3gp" to "video/3gpp",
        )

        /** Null for anything the gallery does not show, an SVG or a TIFF among them. */
        fun of(path: String): GalleryTarget? {
            val name = FilePath.name(path)
            val extension = FileGlyph.extensionOf(name)
            imageTypes[extension]?.let { return GalleryTarget(name, it, isVideo = false) }
            videoTypes[extension]?.let { return GalleryTarget(name, it, isVideo = true) }
            return null
        }
    }
}

/** A save to the gallery: the bytes the preview already holds, or a download straight into the gallery. */
sealed interface GallerySave {
    val target: GalleryTarget

    class FromPreview(override val target: GalleryTarget, val bytes: ByteArray) : GallerySave

    data class Download(override val target: GalleryTarget, val path: String) : GallerySave
}
