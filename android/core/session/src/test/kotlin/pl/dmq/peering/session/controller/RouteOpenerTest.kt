@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakePinStore

class RouteOpenerTest {
    private val stale = PeerAddress("10.9.9.9", 51599)

    @Test
    fun aPairedHostIsDialledAtItsFreshlyResolvedAddressNotTheRememberedOne() = runTest {
        val rig = rig(ConnectTarget.Lan(stale, ScriptedPairingHost.HOST_ID))

        rig.controller.connect()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(listOf<ControlRoute>(ControlRoute.Direct(ControllerRig.LAN_ADDRESS)), rig.routes)
    }

    @Test
    fun aRefusingPortIsFollowedByTheDefaultPortOnTheSameAddress() = runTest {
        val rig = rig(ConnectTarget.Lan(stale))
        rig.refusing += stale

        rig.controller.connect()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(
            listOf<ControlRoute>(ControlRoute.Direct(stale), ControlRoute.Direct(stale.copy(port = 51515))),
            rig.routes,
        )
        assertTrue(rig.controller.state.value.phase !is SessionPhase.Failed)
    }

    @Test
    fun aHostThatIsUnreachableForAnotherReasonIsNotRetriedOnTheDefaultPort() = runTest {
        val rig = rig(ConnectTarget.Lan(stale))
        rig.reachable = false

        rig.controller.connect()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(1, rig.routes.size)
    }

    private fun kotlinx.coroutines.test.TestScope.rig(target: ConnectTarget) = ControllerRig(
        backgroundScope,
        testScheduler,
        target,
        pins = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY)),
    )
}
