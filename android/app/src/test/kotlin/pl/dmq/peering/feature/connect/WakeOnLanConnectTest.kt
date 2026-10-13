package pl.dmq.peering.feature.connect

import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.pairing.FakeQrSource

class WakeOnLanConnectTest {
    private fun wakeStates(paired: List<PairedHost>, online: Set<String> = emptySet(), connected: String? = null) =
        HostListing.of(emptyList(), paired, online, connected).paired.associate { it.id to it.wake }

    @Test
    fun `a computer with an address that is not seen can be woken`() {
        assertEquals(mapOf("A" to WakeState.Available), wakeStates(listOf(PairedHost("A", "Alpha", canWake = true))))
    }

    @Test
    fun `a computer seen up or connected needs no waking`() {
        val paired = listOf(PairedHost("A", "Alpha", canWake = true), PairedHost("B", "Bravo", canWake = true))

        assertEquals(mapOf("A" to WakeState.Awake, "B" to WakeState.Awake), wakeStates(paired, online = setOf("A"), connected = "B"))
    }

    @Test
    fun `no address on file is told before the awake state`() {
        assertEquals(mapOf("A" to WakeState.NoAddress), wakeStates(listOf(PairedHost("A", "Alpha")), online = setOf("A")))
    }

    private fun presenter(sent: Int?, scope: kotlinx.coroutines.CoroutineScope, woken: MutableList<String> = mutableListOf()) = ConnectPresenter(
        hosts = FakeHostSource(paired = listOf(PairedHost("A", "Alpha", canWake = true))),
        presence = FakePresenceSource(),
        qrSource = FakeQrSource(),
        onConnect = {},
        onPair = {},
        onConnectAddress = {},
        onWake = { id ->
            woken += id
            sent
        },
        scope = scope,
    )

    @Test
    fun `waking says how many addresses the packet went to`() = runTest(UnconfinedTestDispatcher()) {
        val woken = mutableListOf<String>()
        val presenter = presenter(sent = 2, scope = backgroundScope, woken = woken)

        presenter.wake("A")

        assertEquals(listOf("A"), woken)
        assertEquals(ConnectMessage.WakeSent(2), presenter.state.value.message)
        assertFalse(presenter.state.value.message!!.isFailure)
    }

    @Test
    fun `no address on file and no readable address are reported as failures`() = runTest(UnconfinedTestDispatcher()) {
        val none = presenter(sent = null, scope = backgroundScope)
        none.wake("A")
        assertEquals(ConnectMessage.WakeNoAddress, none.state.value.message)
        assertTrue(none.state.value.message!!.isFailure)

        val unreadable = presenter(sent = 0, scope = backgroundScope)
        unreadable.wake("A")
        assertEquals(ConnectMessage.WakeUnreadable, unreadable.state.value.message)
    }
}
