package pl.dmq.peering.platform.net

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress

class UdpLaneTest {
    private val loopback = "127.0.0.1"
    private val timeoutMs = 5_000L

    @Test
    fun datagramArrivesWithTheSourceAddressOfTheSendingPort() {
        val sender = UdpLane.bind()
        val receiver = UdpLane.bind()
        try {
            val payload = byteArrayOf(1, 2, 3, 4)
            val arrived = runBlocking {
                sender.send(payload, PeerAddress(loopback, receiver.localPort))
                withTimeout(timeoutMs) { receiver.received.first() }
            }

            assertArrayEquals(payload, arrived.bytes)
            assertEquals(PeerAddress(loopback, sender.localPort), arrived.source)
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @Test
    fun oneSocketReachesTwoDestinations() {
        val lane = UdpLane.bind()
        val relay = UdpLane.bind()
        val direct = UdpLane.bind()
        try {
            runBlocking {
                lane.send(byteArrayOf(0x0A), PeerAddress(loopback, relay.localPort))
                lane.send(byteArrayOf(0x0B), PeerAddress(loopback, direct.localPort))
                val fromRelay = withTimeout(timeoutMs) { relay.received.first() }
                val fromDirect = withTimeout(timeoutMs) { direct.received.first() }

                assertArrayEquals(byteArrayOf(0x0A), fromRelay.bytes)
                assertArrayEquals(byteArrayOf(0x0B), fromDirect.bytes)
                assertEquals(lane.localPort, fromRelay.source.port)
                assertEquals(lane.localPort, fromDirect.source.port)
            }
        } finally {
            lane.close()
            relay.close()
            direct.close()
        }
    }

    @Test
    fun closingTheLaneCompletesReceive() {
        val lane = UdpLane.bind()
        lane.close()

        val received = runBlocking { withTimeout(timeoutMs) { lane.received.toList() } }

        assertEquals(emptyList<Any>(), received)
    }
}
