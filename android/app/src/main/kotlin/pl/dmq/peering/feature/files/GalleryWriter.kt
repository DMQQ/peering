package pl.dmq.peering.feature.files

/** Puts pictures and videos into the phone's gallery, and tells the user how it went. */
interface GalleryWriter {
    /** Writes [bytes] as a finished item; false when it could not. */
    suspend fun write(target: GalleryTarget, bytes: ByteArray): Boolean

    /** A hidden item a download fills, as a content address, or null when none could be made. */
    suspend fun reserve(target: GalleryTarget): String?

    fun report(saved: Boolean)
}
