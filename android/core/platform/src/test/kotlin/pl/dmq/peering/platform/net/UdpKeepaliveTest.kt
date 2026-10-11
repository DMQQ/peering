package pl.dmq.peering.platform.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UdpKeepaliveTest {
    @Test
    fun bindDatagramIsTheTokenAlone() {
        val token = ByteArray(16) { it.toByte() }

        assertArrayEquals(token, UdpKeepalive.bindDatagram(token))
    }

    @Test
    fun bindDatagramRefusesATokenOfAnotherLength() {
        assertThrows(IllegalArgumentException::class.java) {
            UdpKeepalive.bindDatagram(ByteArray(15))
        }
    }

    @Test
    fun keepaliveIntervalIsTenSeconds() {
        assertEquals(10_000L, UdpKeepalive.INTERVAL_MS)
    }
}
