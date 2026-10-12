package pl.dmq.peering.session.controller

/** Receives downloaded bytes in the order they arrive. The platform owns the file and its cleanup on failure. */
fun interface DownloadWriter {
    fun writeRange(offset: Long, bytes: ByteArray)

    /** Pieces handed to [writeRange] and not yet written; the browser holds further reads back while this is high. */
    val backlog: Int get() = 0
}
