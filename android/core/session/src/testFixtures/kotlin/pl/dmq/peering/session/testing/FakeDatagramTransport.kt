package pl.dmq.peering.session.testing

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.ReceivedDatagram

/** Records each datagram with its destination and delivers scripted ones. */
class FakeDatagramTransport : DatagramTransport {
    val sent = mutableListOf<Pair<PeerAddress, ByteArray>>()

    private val inbound = Channel<ReceivedDatagram>(Channel.UNLIMITED)

    override val received: Flow<ReceivedDatagram> = inbound.receiveAsFlow()

    fun deliver(datagram: ReceivedDatagram) {
        inbound.trySend(datagram).getOrThrow()
    }

    override suspend fun send(bytes: ByteArray, destination: PeerAddress) {
        sent += destination to bytes
    }
}
