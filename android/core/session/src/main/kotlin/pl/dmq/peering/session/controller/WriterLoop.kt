package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameEncoder

/**
 * Writes frames to the control connection in the order they were queued. Queueing never waits, so the handshake, the
 * pings and the coalesced commands can all queue from one thread. A frame queued after the link ends is dropped with it.
 */
internal class WriterLoop(private val transport: ControlTransport) {
    private val outbound = Channel<Frame>(Channel.UNLIMITED)

    fun enqueue(frame: Frame) {
        outbound.trySend(frame)
    }

    suspend fun run() {
        for (frame in outbound) {
            transport.send(FrameEncoder.encode(frame.kind, frame.payload))
        }
    }
}
