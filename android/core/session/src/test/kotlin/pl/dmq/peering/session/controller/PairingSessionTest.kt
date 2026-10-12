@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.testing.FakePinStore

class PairingSessionTest {
    @Test
    fun aSasPairingShowsTheCodeAndRecordsThePinOnceTheUserConfirms() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)

        rig.controller.connect()
        settle()

        val code = (rig.controller.state.value.phase as SessionPhase.ConfirmingPairing).code
        assertEquals(rig.mac.connections.single().host.shownCode, code)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))

        rig.controller.confirmPairing(true)
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertArrayEquals(ScriptedPairingHost.HOST_KEY, pins.pin(ScriptedPairingHost.HOST_ID))
        assertEquals(true, rig.mac.connections.single().host.confirmation?.accepted)
    }

    @Test
    fun aDeclinedCodeEndsTheSessionAsFailedAndRecordsNoPin() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)

        rig.controller.connect()
        settle()
        rig.controller.confirmPairing(false)
        settle()

        val failed = rig.controller.state.value.phase as SessionPhase.Failed
        assertEquals(SessionFailure.Handshake(FailureReason.PairingDeclined), failed.reason)
        assertTrue(failed.canRetry)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun aHostThatRefusesThePairingEndsTheSessionWithItsReason() = runTest {
        val rig = pairingRig(mac = ScriptedMac(alreadyPaired = false, refusal = "Another phone is pairing"))

        rig.controller.connect()
        settle()
        rig.controller.confirmPairing(true)
        settle()

        assertEquals(
            SessionFailure.Handshake(FailureReason.PairingRefused("Another phone is pairing")),
            (rig.controller.state.value.phase as SessionPhase.Failed).reason,
        )
    }

    private fun TestScope.pairingRig(
        pins: FakePinStore = FakePinStore(),
        mac: ScriptedMac = ScriptedMac(alreadyPaired = false),
    ): ControllerRig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID), mac, pins)

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
