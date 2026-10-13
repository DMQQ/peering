package pl.dmq.peering.session.ports

import kotlinx.coroutines.flow.Flow

/** One unconnected UDP socket on a local port, which may talk to several peers. */
interface DatagramTransport {
    /** Sends [bytes] from the local port to [destination]. */
    suspend fun send(bytes: ByteArray, destination: PeerAddress)

    /** Datagrams arriving on the local port, each with its source. Completes when the socket closes. */
    val received: Flow<ReceivedDatagram>
}
