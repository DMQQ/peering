package pl.dmq.peering.session.controller

/** Receives downloaded bytes in the order they arrive. The platform owns the file and its cleanup on failure. */
fun interface DownloadWriter {
    fun writeRange(offset: Long, bytes: ByteArray)
}
