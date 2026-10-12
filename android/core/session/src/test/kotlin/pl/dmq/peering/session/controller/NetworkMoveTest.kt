@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.PeerAddress

class NetworkMoveTest {
    private val stale = PeerAddress("10.9.9.9", 51515)

    @Test
    fun aDiscoveryThatCannotStartFallsBackToTheRelayInsteadOfThrowing() = runTest {
        val rig = paired(discovered = null)
        rig.discoveryFails = true
        rig.signalling.grantSession()

        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()

        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)
        assertTrue(rig.logged.any { "discovery failed" in it })
    }

    @Test
    fun pairingWithADiscoveryThatCannotStartFailsAsHostNotFound() = runTest {
        val rig = ControllerRig(
            backgroundScope,
            testScheduler,
            ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID),
        )
        rig.discoveryFails = true

        rig.controller.connect()
        settle()

        assertEquals(SessionPhase.Failed(SessionFailure.HostNotFound, canRetry = true), rig.controller.state.value.phase)
    }

    @Test
    fun aReconnectResolvesTheHostAgainInsteadOfDialingTheAddressItHadBefore() = runTest {
        val rig = paired(discovered = stale)
        rig.controller.connect()
        settle()
        assertEquals(ControlRoute.Direct(stale), rig.controlRoutes.single())

        rig.hostAddress = ControllerRig.LAN_ADDRESS
        rig.mac.answersPings = false
        advanceTimeBy(3_300)
        runCurrent()
        rig.mac.answersPings = true
        advanceTimeBy(5_000)
        runCurrent()

        assertEquals(ControlRoute.Direct(ControllerRig.LAN_ADDRESS), rig.controlRoutes.last())
    }

    @Test
    fun aNetworkChangeRestartsADialThatIsWaitingOnDiscovery() = runTest {
        val rig = ControllerRig(
            backgroundScope,
            testScheduler,
            ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID),
            nobodyDiscovered = true,
        )
        rig.controller.connect()
        advanceTimeBy(2_000)
        runCurrent()
        assertTrue(rig.controlRoutes.isEmpty())

        rig.hostVisible = true
        rig.controller.networkChanged()
        runCurrent()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(listOf<ControlRoute>(ControlRoute.Direct(ControllerRig.LAN_ADDRESS)), rig.controlRoutes)
    }

    @Test
    fun aLinkThatReachedReadyRestartsTheReconnectWindowEvenWithoutAPicture() = runTest {
        val rig = paired(discovered = ControllerRig.LAN_ADDRESS, relayAllowed = false)
        rig.controller.connect()
        settle()
        rig.mac.answersPings = false
        advanceTimeBy(3_300)
        runCurrent()
        rig.reachable = false
        advanceTimeBy(24_000)
        runCurrent()
        rig.reachable = true
        rig.mac.answersPings = true
        advanceTimeBy(8_000)
        runCurrent()
        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)

        rig.mac.answersPings = false
        rig.reachable = false
        advanceTimeBy(5_000)
        runCurrent()

        assertTrue(rig.controller.state.value.phase.toString(), rig.controller.state.value.phase is SessionPhase.Reconnecting)
    }

    private fun TestScope.paired(discovered: PeerAddress?, relayAllowed: Boolean = true) = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Paired(ScriptedPairingHost.HOST_ID, discovered, remembered = null, relayAllowed = relayAllowed),
    )

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
