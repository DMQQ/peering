package pl.dmq.peering.session.ports

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeControlTransport
import pl.dmq.peering.session.testing.FakePinStore

class FakePortsTest {
    @Test
    fun scriptedChunksReachTheSessionAndItsWritesAreRecorded() = runTest {
        val transport = FakeControlTransport(peerKey = byteArrayOf(4))
        transport.script(byteArrayOf(1, 2, 3))

        assertArrayEquals(byteArrayOf(1, 2, 3), transport.received.first())

        transport.send(byteArrayOf(9))
        assertEquals(1, transport.sent.size)
        assertArrayEquals(byteArrayOf(9), transport.sent.single())
        assertArrayEquals(byteArrayOf(4), transport.peerPublicKey())
    }

    @Test
    fun aPinWriteThatFailsIsReportedAndNothingIsStored() {
        val pins = FakePinStore()
        pins.writesSucceed = false

        assertFalse(pins.record("host-a", byteArrayOf(4)))
        assertNull(pins.pin("host-a"))
    }

    @Test
    fun aPinWriteThatSucceedsCanBeReadBack() {
        val pins = FakePinStore()

        assertTrue(pins.record("host-a", byteArrayOf(4, 5)))
        assertArrayEquals(byteArrayOf(4, 5), pins.pin("host-a"))
    }
}
