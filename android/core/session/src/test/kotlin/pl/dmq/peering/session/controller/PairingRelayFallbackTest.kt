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
import pl.dmq.peering.session.testing.FakePinStore

class PairingRelayFallbackTest {
    @Test
    fun aHostSeenOnTheNetworkIsPairedLocallyWithoutAskingTheRelay() = runTest {
        val rig = rig(relayAllowed = true)
        rig.controller.connect()
        settle(1_000)

        assertEquals(listOf<ControlRoute>(ControlRoute.Direct(ControllerRig.LAN_ADDRESS)), rig.controlRoutes)
        assertTrue(rig.signalling.sent.isEmpty())
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)
    }

    @Test
    fun aLocalDialThatFailsFallsBackToTheRelayAndStillAsksForTheCode() = runTest {
        val rig = rig(relayAllowed = true)
        rig.refusing += ControllerRig.LAN_ADDRESS
        rig.refusing += ControllerRig.LAN_ADDRESS.copy(port = ConnectAddresses.DEFAULT_PORT)
        rig.signalling.grantSession()
        rig.controller.connect()
        settle(1_000)

        assertTrue(rig.controlRoutes.last() is ControlRoute.Relayed)
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)
    }

    @Test
    fun aHostNobodySeesIsPairedThroughTheRelay() = runTest {
        val rig = rig(relayAllowed = true, nobodyDiscovered = true)
        rig.signalling.grantSession()
        rig.controller.connect()
        settle(11_000)

        assertTrue(rig.controlRoutes.single() is ControlRoute.Relayed)
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)
    }

    @Test
    fun withTheRelayForbiddenAHostNobodySeesIsNotFound() = runTest {
        val rig = rig(relayAllowed = false, nobodyDiscovered = true)
        rig.controller.connect()
        settle(11_000)

        assertEquals(SessionFailure.HostNotFound, (rig.controller.state.value.phase as SessionPhase.Failed).reason)
        assertTrue(rig.signalling.sent.isEmpty())
    }

    private fun TestScope.rig(relayAllowed: Boolean, nobodyDiscovered: Boolean = false) = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID, relayAllowed = relayAllowed),
        ScriptedMac(alreadyPaired = false),
        FakePinStore(),
        nobodyDiscovered = nobodyDiscovered,
    )

    private suspend fun TestScope.settle(millis: Long) {
        advanceTimeBy(millis)
        runCurrent()
    }
}
