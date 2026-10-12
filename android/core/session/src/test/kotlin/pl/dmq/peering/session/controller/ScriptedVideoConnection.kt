package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder

/** The Mac's end of a LAN picture connection: it records what the phone wrote and streams what a test delivers. */
class ScriptedVideoConnection : ControlTransport {
    private val inbound = Channel<ByteArray>(Channel.UNLIMITED)
    private val decoder = FrameDecoder()

    /** Every frame the phone wrote, in order. The first must be the video role. */
    val phoneFrames = mutableListOf<Frame>()

    var closed = false
        private set

    override val received: Flow<ByteArray> = inbound.receiveAsFlow()

    override suspend fun send(bytes: ByteArray) {
        decoder.push(bytes)
        while (true) phoneFrames += decoder.next() ?: break
    }

    override fun close() {
        closed = true
        inbound.close()
    }

    override fun peerPublicKey(): ByteArray = byteArrayOf()

    fun deliver(frame: Frame) {
        inbound.trySend(FrameEncoder.encode(frame.kind, frame.payload))
    }

    fun hostCloses() {
        inbound.close()
    }
}
