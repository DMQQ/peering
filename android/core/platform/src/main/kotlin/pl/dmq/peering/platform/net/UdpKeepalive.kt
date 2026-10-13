package pl.dmq.peering.platform.net

import kotlinx.coroutines.delay
import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.PeerAddress

/** The relay token is the whole bind and keepalive datagram; the relay routes by it, so nothing else is sent. */
object UdpKeepalive {
    const val TOKEN_SIZE = 16
    const val INTERVAL_MS = 10_000L

    fun bindDatagram(token: ByteArray): ByteArray {
        require(token.size == TOKEN_SIZE) { "video token must be $TOKEN_SIZE bytes" }
        return token.copyOf()
    }

    /** Sends the token to [destination] now and then every [INTERVAL_MS] until the coroutine is cancelled. */
    suspend fun run(lane: DatagramTransport, destination: PeerAddress, token: ByteArray) {
        val datagram = bindDatagram(token)
        while (true) {
            lane.send(datagram, destination)
            delay(INTERVAL_MS)
        }
    }
}
