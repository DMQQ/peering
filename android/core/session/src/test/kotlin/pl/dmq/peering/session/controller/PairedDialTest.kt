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

class PairedDialTest {
    private val earlier = PeerAddress("192.0.2.77", 51515)

    @Test
    fun aDiscoveredHostConnectsOverTheLocalNetworkWithoutTouchingTheRelay() = runTest {
        val rig = rig(discovered = ControllerRig.LAN_ADDRESS)
        rig.controller.connect()
        settle()

        assertEquals(listOf<ControlRoute>(ControlRoute.Direct(ControllerRig.LAN_ADDRESS)), rig.controlRoutes)
        assertEquals(SessionRecord.Path.LAN, (rig.controller.state.value.phase as SessionPhase.Ready).path)
        assertTrue(rig.signalling.sent.isEmpty())
    }

    @Test
    fun aFailedLocalDialFallsBackToTheRelayAndReportsRelay() = runTest {
        val rig = rig(discovered = ControllerRig.LAN_ADDRESS)
        rig.refusing += ControllerRig.LAN_ADDRESS
        rig.refusing += ControllerRig.LAN_ADDRESS.copy(port = 51515)
        rig.signalling.grantSession()

        rig.controller.connect()
        settle()

        assertTrue(rig.controlRoutes.last() is ControlRoute.Relayed)
        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)
    }

    @Test
    fun aRememberedAddressIsDialledBeforeDiscoveryAnswersAndTheRelayIsNotAskedWhileItWorks() = runTest {
        val rig = rig(remembered = ControllerRig.LAN_ADDRESS)
        rig.controller.connect()
        settle()

        assertEquals(ControlRoute.Direct(ControllerRig.LAN_ADDRESS), rig.controlRoutes.first())
        assertEquals(SessionRecord.Path.LAN, (rig.controller.state.value.phase as SessionPhase.Ready).path)
        assertTrue(rig.signalling.sent.isEmpty())
    }

    @Test
    fun aDeadRememberedAddressMovesToTheRelayWithoutWaitingForTheTimeout() = runTest {
        val rig = rig(remembered = earlier)
        rig.refusing += earlier
        rig.refusing += earlier.copy(port = 51515)
        rig.signalling.grantSession()

        rig.controller.connect()
        settle()

        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)
    }

    @Test
    fun aHostUnknownToTheNetworkButSeenByDiscoveryInTheGraceIsDialledLocally() = runTest {
        val rig = rig()
        rig.signalling.grantSession()
        rig.controller.connect()
        settle()

        assertEquals(ControlRoute.Direct(ControllerRig.LAN_ADDRESS), rig.controlRoutes.first())
        assertEquals(SessionRecord.Path.LAN, (rig.controller.state.value.phase as SessionPhase.Ready).path)
    }

    @Test
    fun theRelayIsUsedWhenItIsTheOnlyRouteAllowedAndNothingIsKnown() = runTest {
        val rig = rig(relayAllowed = true, nobodyDiscovered = true)
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(2_000)
        runCurrent()

        assertTrue(rig.controlRoutes.single() is ControlRoute.Relayed)
    }

    @Test
    fun withTheRelayForbiddenAndNobodyAroundTheHostIsNotFound() = runTest {
        val rig = rig(relayAllowed = false, nobodyDiscovered = true)
        rig.controller.connect()
        advanceTimeBy(2_000)
        runCurrent()

        assertEquals(SessionFailure.HostNotFound, (rig.controller.state.value.phase as SessionPhase.Failed).reason)
    }

    private fun TestScope.rig(
        discovered: PeerAddress? = null,
        remembered: PeerAddress? = null,
        relayAllowed: Boolean = true,
        nobodyDiscovered: Boolean = false,
    ) = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Paired(ScriptedPairingHost.HOST_ID, discovered, remembered, relayAllowed),
        nobodyDiscovered = nobodyDiscovered,
    )
}
