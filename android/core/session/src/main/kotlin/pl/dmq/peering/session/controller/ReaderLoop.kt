package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.flow.Flow
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder

/**
 * Cuts the control byte stream into frames and passes them on in order. The frame channel is closed when the stream ends
 * or fails, so whoever reads frames sees the connection end as a closed channel.
 */
internal class ReaderLoop(private val bytes: Flow<ByteArray>, private val frames: SendChannel<Frame>) {
    suspend fun run() {
        val decoder = FrameDecoder()
        try {
            bytes.collect { chunk ->
                decoder.push(chunk)
                while (true) {
                    val frame = decoder.next() ?: break
                    frames.send(frame)
                }
            }
        } finally {
            frames.close()
        }
    }
}
