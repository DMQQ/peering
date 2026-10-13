package pl.dmq.peering.session.wake

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WakeOnLanTest {
    @Test
    fun `the packet is six ff bytes then the address sixteen times`() {
        val packet = WakeOnLan.magicPacket("aa:BB:0c:01:02:ff")!!

        assertEquals(102, packet.size)
        assertArrayEquals(ByteArray(6) { 0xFF.toByte() }, packet.copyOfRange(0, 6))
        val octets = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0x0C, 1, 2, 0xFF.toByte())
        repeat(16) { assertArrayEquals(octets, packet.copyOfRange(6 + it * 6, 12 + it * 6)) }
    }

    @Test
    fun `an address that is not six pairs of hex digits makes no packet`() {
        listOf("", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aa:bb:cc:dd:ee:f", "aa-bb-cc-dd-ee-ff", "gg:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:fff").forEach {
            assertNull(it, WakeOnLan.magicPacket(it))
        }
    }

    @Test
    fun `both the usual port and the fallback are sent to`() {
        assertEquals(listOf(9, 7), WakeOnLan.PORTS)
    }
}
