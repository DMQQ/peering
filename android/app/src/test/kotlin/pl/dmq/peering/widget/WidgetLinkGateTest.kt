package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WidgetLinkGateTest {
    private val nonce = "a".repeat(64)
    private val gate = WidgetLinkGate(nonce)

    private fun fromWidget(address: String) = WidgetLinkGate.requestFor(address, nonce)

    @Test
    fun theWidgetsRequestCarriesTheAddressAndTheInstallsNonce() {
        val request = WidgetLinkGate.requestFor(WidgetLink.connect("mac 1"), nonce)

        assertEquals("peering://connect?id=mac+1", request.data)
        assertEquals(nonce, request.nonce)
    }

    @Test
    fun aRequestWithTheRightNonceActsAtOnceWhileUnlocked() {
        val acted = gate.receive(fromWidget(WidgetLink.chat("c1", "h1")), locked = false)

        assertEquals(WidgetLink.Chat("c1", "h1"), acted)
        assertNull(gate.released())
    }

    @Test
    fun aRequestWhileLockedWaitsAndReplaysOnceOnUnlock() {
        assertNull(gate.receive(fromWidget(WidgetLink.connect("h1")), locked = true))

        assertEquals(WidgetLink.Connect("h1"), gate.released())
        assertNull(gate.released())
    }

    @Test
    fun aForgedOrMissingNonceNeitherActsNorQueues() {
        val address = WidgetLink.connect("h1")

        assertNull(gate.receive(LinkRequest(address, "b".repeat(64)), locked = false))
        assertNull(gate.receive(LinkRequest(address, null), locked = false))
        assertNull(gate.receive(LinkRequest(address, "b".repeat(64)), locked = true))
        assertNull(gate.released())
    }

    @Test
    fun aForgedLinkSentWhileLockedDoesNotReplaceTheRealHeldOne() {
        gate.receive(fromWidget(WidgetLink.connect("real")), locked = true)
        gate.receive(LinkRequest(WidgetLink.connect("forged"), null), locked = true)

        assertEquals(WidgetLink.Connect("real"), gate.released())
    }

    @Test
    fun anAddressThatIsNotAWidgetLinkIsDroppedEvenWithTheRightNonce() {
        assertNull(gate.receive(fromWidget("https://example.com/"), locked = false))
        assertNull(gate.receive(fromWidget("peering://other"), locked = false))
        assertNull(gate.receive(fromWidget(""), locked = true))
        assertNull(gate.released())
    }
}
