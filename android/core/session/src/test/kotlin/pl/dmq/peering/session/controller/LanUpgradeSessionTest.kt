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

class LanUpgradeSessionTest {
    @Test
    fun aRelayedSessionMovesToTheLanOnceTheMacHasStayedInViewForThreeSeconds() = runTest {
        val rig = relayedWithMacOffTheLan()
        rig.hostVisible = true

        rig.controller.networkChanged()
        advanceTimeBy(2_500)
        runCurrent()
        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)

        advanceTimeBy(2_500)
        runCurrent()
        assertTrue(rig.controlRoutes.last() is ControlRoute.Direct)
    }

    private suspend fun TestScope.relayedWithMacOffTheLan(): ControllerRig {
        val rig = ControllerRig(
            backgroundScope,
            testScheduler,
            ConnectTarget.Paired(ScriptedPairingHost.HOST_ID, discovered = null, remembered = null, relayAllowed = true),
            nobodyDiscovered = true,
        )
        rig.signalling.grantSession()
        rig.controller.connect()
        advanceTimeBy(4_000)
        runCurrent()
        assertEquals(SessionRecord.Path.RELAY, (rig.controller.state.value.phase as SessionPhase.Ready).path)
        return rig
    }
}
