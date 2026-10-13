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
        advanceTimeBy(4_000)
        runCurrent()

        assertTrue(rig.controlRoutes.single() is ControlRoute.Relayed)
    }

    @Test
    fun withTheRelayForbiddenAndNobodyAroundTheHostIsNotFound() = runTest {
        val rig = rig(relayAllowed = false, nobodyDiscovered = true)
        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()

        assertEquals(SessionFailure.HostNotFound, (rig.controller.state.value.phase as SessionPhase.Failed).reason)
    }

    @Test
    fun aHostThatDiscoveryResolvesSlowlyIsStillReachedOverTheLocalNetwork() = runTest {
        val rig = rig(discoveryDelayMillis = 2_500)
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(3_000)
        runCurrent()

        assertTrue(rig.controlRoutes.single() is ControlRoute.Direct)
        assertEquals(SessionRoute.Direct, rig.controller.state.value.route)
        assertTrue(rig.signalling.sent.isEmpty())
    }

    @Test
    fun aLocalSessionReportsTheAddressItReachedSoTheNextDialCanStartThere() = runTest {
        val rig = rig(discovered = ControllerRig.LAN_ADDRESS)
        rig.controller.connect()
        settle()

        assertEquals(ControllerRig.LAN_ADDRESS, rig.reachedOnLan[ScriptedPairingHost.HOST_ID])
    }

    @Test
    fun aRelayedSessionReportsNoLocalAddressAndTheRelayRoute() = runTest {
        val rig = rig(relayAllowed = true, nobodyDiscovered = true)
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()

        assertTrue(rig.reachedOnLan.isEmpty())
        assertEquals(SessionRoute.Relay, rig.controller.state.value.route)
    }

    @Test
    fun theRouteIsKnownWhileConnectingAndTheDialIsLogged() = runTest {
        val rig = rig(discovered = ControllerRig.LAN_ADDRESS)
        rig.controller.connect()

        assertEquals(SessionRoute.Direct, rig.controller.state.value.route)
        settle()
        assertTrue(rig.logged.any { "192.0.2.10" in it })
    }

    @Test
    fun aRelayedSessionMovesToTheLocalNetworkWhenTheNetworkChangesAndTheHostIsThere() = runTest {
        val rig = rig(nobodyDiscovered = true)
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()
        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)

        rig.hostVisible = true
        rig.controller.networkChanged()
        advanceTimeBy(1_000)
        runCurrent()

        assertEquals(ControlRoute.Direct(ControllerRig.LAN_ADDRESS), rig.controlRoutes.last())
        assertEquals(SessionRecord.Path.LAN, (rig.controller.state.value.phase as SessionPhase.Ready).path)
    }

    @Test
    fun aRelayedSessionStaysPutWhenTheNetworkChangesAndTheHostIsNotOnIt() = runTest {
        val rig = rig(nobodyDiscovered = true)
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()

        rig.controller.networkChanged()
        advanceTimeBy(6_000)
        runCurrent()

        assertEquals(1, rig.controlRoutes.size)
        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)
    }

    private fun TestScope.rig(
        discovered: PeerAddress? = null,
        remembered: PeerAddress? = null,
        relayAllowed: Boolean = true,
        nobodyDiscovered: Boolean = false,
        discoveryDelayMillis: Long = 0,
    ) = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Paired(ScriptedPairingHost.HOST_ID, discovered, remembered, relayAllowed),
        nobodyDiscovered = nobodyDiscovered,
        discoveryDelayMillis = discoveryDelayMillis,
    )
}
