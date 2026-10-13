@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.SetStreamQuality

class PowerSavingSessionTest {
    @Test
    fun `power saving holds the picture at medium and 30 frames, and leaving it lifts the cap`() = runTest {
        val rig = lanRig()
        rig.controller.connect()
        settle()
        assertEquals(0, rig.lastQuality().fps)

        rig.powerSaving = true
        rig.controller.powerSavingChanged()
        settle()
        assertEquals(30, rig.lastQuality().fps)
        assertEquals(QualityTier.MEDIUM, rig.controller.state.value.qualityCeiling)
        assertEquals(QualityTier.MEDIUM.kbps, rig.lastQuality().bitrateKbps)

        rig.powerSaving = false
        rig.controller.powerSavingChanged()
        settle()
        assertEquals(PowerSaving.UNCAPPED_FRAMES_PER_SECOND, rig.lastQuality().fps)
        assertEquals(QualityTier.HIGH, rig.controller.state.value.qualityCeiling)
    }

    @Test
    fun `a session that starts while saving power is held from the first rate`() = runTest {
        val rig = lanRig()
        rig.powerSaving = true

        rig.controller.connect()
        settle()

        assertEquals(30, rig.commands().first().fps)
        assertEquals(QualityTier.MEDIUM, rig.controller.state.value.qualityCeiling)
    }

    @Test
    fun `the ceiling and the frame rate rules`() {
        assertEquals(QualityTier.MEDIUM, PowerSaving.ceiling(QualityTier.HIGH, powerSaving = true))
        assertEquals(QualityTier.LOW, PowerSaving.ceiling(QualityTier.LOW, powerSaving = true))
        assertEquals(QualityTier.HIGH, PowerSaving.ceiling(QualityTier.HIGH, powerSaving = false))
        assertEquals(30, PowerSaving.framesPerSecond(powerSaving = true, wasCapped = false))
        assertEquals(120, PowerSaving.framesPerSecond(powerSaving = false, wasCapped = true))
        assertEquals(0, PowerSaving.framesPerSecond(powerSaving = false, wasCapped = false))
        assertEquals(QualityTier.MEDIUM, QualityCeiling.of(SessionRecord.Path.LAN, unlimitedRelay = true, powerSaving = true))
    }

    private fun ControllerRig.commands(): List<SetStreamQuality> =
        mac.connections.single().phoneFrames.commands().filterIsInstance<SetStreamQuality>()

    private fun ControllerRig.lastQuality(): SetStreamQuality = commands().last()

    private fun TestScope.lanRig(): ControllerRig =
        ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))

    private suspend fun TestScope.settle() {
        advanceTimeBy(300)
        runCurrent()
    }
}
