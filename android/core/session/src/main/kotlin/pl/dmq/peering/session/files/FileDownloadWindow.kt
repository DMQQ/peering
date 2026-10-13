package pl.dmq.peering.session.files

import kotlin.math.max

/**
 * Which pieces of a download to ask for next. Pure arithmetic: every step returns the new window and the offsets
 * to request, and the caller sends them.
 */
data class FileDownloadWindow(
    val totalBytes: Long? = null,
    val requestedUpTo: Long = 0,
    val receivedBytes: Long = 0,
    val inFlight: Int = 0,
) {
    val isComplete: Boolean get() = totalBytes?.let { receivedBytes >= it } ?: false

    /** 0 to 1, or null until the size is known. */
    val fraction: Double?
        get() = totalBytes?.takeIf { it > 0 }?.let { minOf(1.0, receivedBytes.toDouble() / it) }

    /** The first piece, asked before the size is known. Returns the window and the offset to ask for. */
    fun first(): Pair<FileDownloadWindow, Long> =
        copy(requestedUpTo = TransferLimits.DOWNLOAD_CHUNK_BYTES.toLong(), inFlight = 1) to 0L

    /** Records a piece that arrived, and the offsets to ask for now: enough to keep the window full, never past the end. */
    fun received(count: Int, totalBytes: Long): Pair<FileDownloadWindow, List<Long>> {
        var window = copy(
            totalBytes = totalBytes,
            receivedBytes = receivedBytes + count,
            inFlight = max(0, inFlight - 1),
        )
        val offsets = mutableListOf<Long>()
        while (window.inFlight < TransferLimits.DOWNLOAD_WINDOW && window.requestedUpTo < totalBytes) {
            offsets += window.requestedUpTo
            window = window.copy(
                requestedUpTo = window.requestedUpTo + TransferLimits.DOWNLOAD_CHUNK_BYTES,
                inFlight = window.inFlight + 1,
            )
        }
        return window to offsets
    }
}
