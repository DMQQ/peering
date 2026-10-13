@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.SetStreamQuality

class LanSessionTest {
    @Test
    fun aLanConnectToAPairedHostReachesReadyAndSendsTheQualityOnce() = runTest {
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))

        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        val ready = rig.controller.state.value.phase as SessionPhase.Ready
        assertEquals(ControllerRig.HOST_NAME, ready.hostName)
        assertEquals(SessionRecord.Path.LAN, ready.path)
        assertEquals(listOf(ControlRoute.Direct(ControllerRig.LAN_ADDRESS)), rig.controlRoutes)
        assertEquals(
            listOf(SetStreamQuality(fps = 0, bitrateKbps = QualityTier.HIGH.kbps)),
            rig.mac.connections.single().phoneFrames.commands(),
        )
    }
}
