package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.flow.Flow
import pl.dmq.peering.session.history.ByteTally
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FramingException

/**
 * Cuts the control byte stream into frames and passes them on in order. The frame channel is closed when the stream ends
 * or fails, so whoever reads frames sees the connection end as a closed channel. A malformed frame is reported to
 * [onMalformed] before the channel closes, so the end is known by the time a reader sees the closed channel.
 */
internal class ReaderLoop(
    private val bytes: Flow<ByteArray>,
    private val frames: SendChannel<Frame>,
    private val tally: ByteTally,
    private val onMalformed: () -> Unit,
) {
    suspend fun run() {
        val decoder = FrameDecoder()
        try {
            bytes.collect { chunk ->
                tally.addReceived(chunk.size)
                decoder.push(chunk)
                while (true) {
                    val frame = decoder.next() ?: break
                    frames.send(frame)
                }
            }
        } catch (malformed: FramingException) {
            onMalformed()
        } finally {
            frames.close()
        }
    }
}
