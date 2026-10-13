package pl.dmq.peering.session.files

import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.toBase64

object UploadPlan {
    /**
     * The requests that send one file: `beginWrite` with the declared size, then `writeChunk` pieces, the last one
     * marked `isLast`. [pieces] is read lazily, so a large file never sits in memory whole. A file that ends before
     * its declared size, or an empty file, still gets a final empty `isLast` piece, which tells the Mac to finish.
     */
    fun requests(
        sessionID: String,
        path: String,
        totalBytes: Long,
        pieces: Iterator<ByteArray>,
    ): Sequence<TerminalRequest> = sequence {
        yield(TerminalRequest.BeginWrite(sessionID, path, totalBytes))
        var sent = 0L
        var finished = false
        while (!finished) {
            val piece = if (sent < totalBytes && pieces.hasNext()) pieces.next() else ByteArray(0)
            if (piece.isEmpty()) break
            sent += piece.size
            finished = sent >= totalBytes
            yield(TerminalRequest.WriteChunk(sessionID, path, piece.toBase64(), isLast = finished))
        }
        if (!finished) yield(TerminalRequest.WriteChunk(sessionID, path, "", isLast = true))
    }

    /** The upload's outcome if [event] reports one, else null. */
    fun outcome(event: TerminalEvent): UploadOutcome? = when (event) {
        is TerminalEvent.WroteFile -> UploadOutcome.Written(event.path, event.totalBytes)
        is TerminalEvent.WriteFailure -> UploadOutcome.Failed(event.path, event.message)
        else -> null
    }
}
