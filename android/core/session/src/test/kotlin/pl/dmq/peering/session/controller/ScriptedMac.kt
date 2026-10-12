package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.VIDEO_SECRET_SIZE
import pl.dmq.peering.wire.VideoKeyGrant
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.toBase64

/**
 * The Mac's side of the control connections a controller opens. Each connection runs its own handshake through
 * [ScriptedPairingHost]; pings are answered here unless [answersPings] is cleared, and a video key request is granted.
 * [declare] edits the server hello, so a test can make the host declare the capabilities it needs.
 */
class ScriptedMac(
    private val declare: (ServerHello) -> ServerHello = { it },
    private val alreadyPaired: Boolean = true,
    private val qrSecret: ByteArray? = null,
    private val refusal: String? = null,
    private val garbledHandshake: Boolean = false,
) {
    val connections = mutableListOf<MacConnection>()

    var answersPings = true

    val videoSecret = ByteArray(VIDEO_SECRET_SIZE) { 7 }

    fun newConnection(): MacConnection = MacConnection().also { connections += it }

    inner class MacConnection : ControlTransport {
        private val inbound = Channel<ByteArray>(Channel.UNLIMITED)
        private val decoder = FrameDecoder()
        val host = ScriptedPairingHost(alreadyPaired = alreadyPaired, qrSecret = qrSecret, refusal = refusal)

        /** Every frame the phone wrote on this connection, in order. */
        val phoneFrames = mutableListOf<Frame>()

        var closed = false
            private set

        override val received: Flow<ByteArray> = inbound.receiveAsFlow()

        override suspend fun send(bytes: ByteArray) {
            decoder.push(bytes)
            while (true) {
                val frame = decoder.next() ?: break
                phoneFrames += frame
                answer(frame)
            }
        }

        override fun close() {
            closed = true
            inbound.close()
        }

        override fun peerPublicKey(): ByteArray = ScriptedPairingHost.HOST_KEY

        /** Writes [frame] from the Mac to the phone, as the host would. */
        fun deliver(frame: Frame) {
            deliverBytes(FrameEncoder.encode(frame.kind, frame.payload))
        }

        /** Writes bytes that are not a well-formed frame, as a broken host would. */
        fun deliverBytes(bytes: ByteArray) {
            inbound.trySend(bytes)
        }

        private fun answer(frame: Frame) {
            when (frame.kind) {
                MessageKind.Ping -> if (answersPings) deliver(Frame(MessageKind.Pong, frame.payload))
                MessageKind.VideoKeyRequest -> deliver(videoKey())
                MessageKind.ClientHello -> if (garbledHandshake) deliverBytes(UNKNOWN_KIND_FRAME) else relayHandshake(frame)
                else -> relayHandshake(frame)
            }
        }

        private fun relayHandshake(frame: Frame) {
            host.receive(FrameEncoder.encode(frame.kind, frame.payload)).forEach { deliver(declared(it)) }
        }

        private fun declared(frame: Frame): Frame {
            if (frame.kind != MessageKind.ServerHello) return frame
            val hello = WireJson.decodeFromString(ServerHello.serializer(), frame.payload.decodeToString())
            return Frame(MessageKind.ServerHello, WireJson.encodeToString(ServerHello.serializer(), declare(hello)).toByteArray())
        }

        private fun videoKey(): Frame {
            val grant = VideoKeyGrant(videoSecret.toBase64())
            return Frame(MessageKind.VideoKey, WireJson.encodeToString(VideoKeyGrant.serializer(), grant).toByteArray())
        }
    }
}

/** A frame whose kind byte no phone knows, so the reader must refuse it. */
private val UNKNOWN_KIND_FRAME = byteArrayOf(0, 0, 0, 1, 0xEE.toByte())
