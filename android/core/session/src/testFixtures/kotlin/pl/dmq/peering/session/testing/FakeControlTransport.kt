package pl.dmq.peering.session.testing

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import pl.dmq.peering.session.ports.ControlTransport

/** Replays scripted chunks to the session and records every chunk the session sends. */
class FakeControlTransport(private val peerKey: ByteArray? = null) : ControlTransport {
    val sent = mutableListOf<ByteArray>()

    var closed = false
        private set

    private val inbound = Channel<ByteArray>(Channel.UNLIMITED)

    override val received: Flow<ByteArray> = inbound.receiveAsFlow()

    fun script(chunk: ByteArray) {
        inbound.trySend(chunk).getOrThrow()
    }

    fun endInbound() {
        inbound.close()
    }

    override suspend fun send(bytes: ByteArray) {
        sent += bytes
    }

    override fun close() {
        closed = true
        inbound.close()
    }

    override fun peerPublicKey(): ByteArray? = peerKey
}
