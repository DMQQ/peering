package pl.dmq.peering.feature.agents.preview

import java.io.IOException
import java.io.InputStream
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.runBlocking
import pl.dmq.peering.wire.PreviewProxyEvent

/**
 * A response body read as the computer sends it. [read] blocks for the next piece, which is what a web view's loading
 * thread expects. A body that stops short fails the read, so the page sees a broken reply instead of a short one, and
 * closing the stream tells the computer to stop sending.
 */
class PreviewBodyStream(private val events: ReceiveChannel<PreviewProxyEvent>) : InputStream() {
    private var piece = ByteArray(0)
    private var offset = 0
    private var finished = false

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and BYTE_MASK
    }

    override fun read(buffer: ByteArray, from: Int, length: Int): Int {
        if (length == 0) return 0
        while (offset >= piece.size) {
            if (finished) return -1
            advance()
        }
        val count = minOf(length, piece.size - offset)
        piece.copyInto(buffer, from, offset, offset + count)
        offset += count
        return count
    }

    override fun close() {
        finished = true
        events.cancel()
    }

    private fun advance() {
        when (val event = runBlocking { events.receiveCatching().getOrNull() }) {
            is PreviewProxyEvent.Body -> {
                piece = event.bytes
                offset = 0
            }
            is PreviewProxyEvent.End -> finished = true
            is PreviewProxyEvent.Failure, null -> {
                finished = true
                throw IOException("the preview's reply was cut short")
            }
            is PreviewProxyEvent.Head -> Unit
        }
    }

    private companion object {
        const val BYTE_MASK = 0xFF
    }
}
