package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameEncoder
import kotlin.time.Duration.Companion.seconds

/**
 * Writes frames to the control connection in the order they were queued. Queueing never waits, so the handshake, the
 * pings and the coalesced commands can all queue from one thread. A frame queued after the link ends is dropped with it.
 */
internal class WriterLoop(private val transport: ControlTransport) {
    private val outbound = Channel<Frame>(Channel.UNLIMITED)

    fun enqueue(frame: Frame) {
        outbound.trySend(frame)
    }

    private val drained = CompletableDeferred<Unit>()

    suspend fun run() {
        try {
            for (frame in outbound) {
                transport.send(FrameEncoder.encode(frame.kind, frame.payload))
            }
        } finally {
            drained.complete(Unit)
        }
    }

    /** Lets what is queued reach the connection, for at most [FLUSH_LIMIT], so a last word is not lost to the close. */
    suspend fun flush() {
        outbound.close()
        withTimeoutOrNull(FLUSH_LIMIT) { drained.await() }
    }

    private companion object {
        val FLUSH_LIMIT = 1.seconds
    }
}
