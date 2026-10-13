package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExternalLinkGateTest {
    private val connect = WidgetLink.Connect("h")

    private fun open() = ExternalLinkGate().also { it.setLocked(false) }

    @Test
    fun `a link that arrives before the lock has been checked is held`() {
        val gate = ExternalLinkGate()

        assertNull(gate.submit(connect, hasLiveSession = false))
        assertEquals(connect, gate.setLocked(false))
        assertNull(gate.setLocked(false))
    }

    @Test
    fun `a connect or chat link runs at once when the app is open`() {
        val gate = open()

        assertEquals(connect, gate.submit(connect, hasLiveSession = true))
        assertEquals(WidgetLink.Chat("c", "h"), gate.submit(WidgetLink.Chat("c", "h"), hasLiveSession = true))
    }

    @Test
    fun `ending a live session asks first and runs only on a yes`() {
        val gate = open()

        assertNull(gate.submit(WidgetLink.Disconnect, hasLiveSession = true))
        assertEquals(WidgetLink.Disconnect, gate.confirming)
        assertEquals(WidgetLink.Disconnect, gate.confirm())
        assertNull(gate.confirming)
        assertNull(gate.confirm())
    }

    @Test
    fun `a no drops the question`() {
        val gate = open()
        gate.submit(WidgetLink.Disconnect, hasLiveSession = true)

        gate.cancelConfirmation()

        assertNull(gate.confirm())
    }

    @Test
    fun `disconnecting with nothing running needs no question`() {
        assertEquals(WidgetLink.Disconnect, open().submit(WidgetLink.Disconnect, hasLiveSession = false))
    }

    @Test
    fun `locking drops a pending question so it cannot be accepted behind the lock`() {
        val gate = open()
        gate.submit(WidgetLink.Disconnect, hasLiveSession = true)

        gate.setLocked(true)

        assertNull(gate.confirming)
        assertNull(gate.confirm())
    }

    @Test
    fun `a link held for the lock is the newest one and runs once after the unlock`() {
        val gate = ExternalLinkGate()
        gate.submit(WidgetLink.Connect("a"), hasLiveSession = false)
        gate.submit(WidgetLink.Connect("b"), hasLiveSession = false)

        assertEquals(WidgetLink.Connect("b"), gate.setLocked(false))
        assertNull(gate.setLocked(false))
    }
}
