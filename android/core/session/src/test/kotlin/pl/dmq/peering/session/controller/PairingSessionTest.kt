@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.testing.FakePinStore

class PairingSessionTest {
    @Test
    fun aSasPairingAsksForTheCodeAndRecordsThePinOnceTheRightDigitsAreTyped() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)

        rig.controller.connect()
        settle()

        assertEquals(SessionPhase.EnteringPairingCode(attempts = 0), rig.controller.state.value.phase)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))

        assertEquals(CodeCheck.Match, rig.controller.submitPairingCode(shownCode(rig)))
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertArrayEquals(ScriptedPairingHost.HOST_KEY, pins.pin(ScriptedPairingHost.HOST_ID))
        assertEquals(true, rig.mac.connections.single().host.confirmation?.accepted)
        assertNull(rig.mac.connections.single().host.confirmation?.proofBytes)
    }

    @Test
    fun aWrongCodeIsRefusedAndTheUserCanTryAgain() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)
        rig.controller.connect()
        settle()

        assertEquals(CodeCheck.Mismatch, rig.controller.submitPairingCode(otherThan(shownCode(rig))))

        assertEquals(
            SessionPhase.EnteringPairingCode(attempts = 1, error = PairingCodeError.WrongCode),
            rig.controller.state.value.phase,
        )
        assertNull(rig.mac.connections.single().host.confirmation)

        assertEquals(CodeCheck.Match, rig.controller.submitPairingCode(shownCode(rig)))
        settle()
        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
    }

    @Test
    fun theLastAllowedWrongCodeDeclinesThePairingAndPinsNothing() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)
        rig.controller.connect()
        settle()
        val wrong = otherThan(shownCode(rig))

        repeat(MAX_PAIRING_ATTEMPTS - 1) { assertEquals(CodeCheck.Mismatch, rig.controller.submitPairingCode(wrong)) }
        assertEquals(CodeCheck.TooManyAttempts, rig.controller.submitPairingCode(wrong))
        settle()

        val failed = rig.controller.state.value.phase as SessionPhase.Failed
        assertEquals(SessionFailure.Handshake(FailureReason.PairingDeclined), failed.reason)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun cancellingWhileTheCodeIsAwaitedEndsTheSessionAndPinsNothing() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins = pins)
        rig.controller.connect()
        settle()

        rig.controller.disconnect()
        settle()

        assertEquals(SessionPhase.Ended, rig.controller.state.value.phase)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun aScannedCodeWithItsSecretSendsTheProofWithoutTheUserTyping() = runTest {
        val secret = ByteArray(32) { 0x5A }
        val rig = pairingRig(mac = ScriptedMac(alreadyPaired = false, qrSecret = secret))
        rig.controller.connect()
        settle()

        assertEquals(CodeCheck.Match, rig.controller.submitScannedPairingCode(shownCode(rig), secret))
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertTrue(rig.mac.connections.single().host.confirmation?.proofBytes != null)
    }

    @Test
    fun aScannedCodeThatIsNotTheMacsIsRefused() = runTest {
        val rig = pairingRig()
        rig.controller.connect()
        settle()

        assertEquals(CodeCheck.Mismatch, rig.controller.submitScannedPairingCode(otherThan(shownCode(rig)), ByteArray(32)))
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)
    }

    @Test
    fun aTargetThatAlreadyHoldsTheQrSecretNeverAsksForTheCode() = runTest {
        val secret = ByteArray(32) { 0x5A }
        val rig = ControllerRig(
            backgroundScope,
            testScheduler,
            ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID, secret),
            ScriptedMac(alreadyPaired = false, qrSecret = secret),
            FakePinStore(),
        )
        val phases = mutableListOf<SessionPhase>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { rig.controller.state.collect { phases += it.phase } }

        rig.controller.connect()
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertTrue(phases.none { it is SessionPhase.EnteringPairingCode })
    }

    @Test
    fun theCodeNeverAppearsInAnythingTheControllerPublishes() = runTest {
        val rig = pairingRig()
        rig.controller.connect()
        settle()
        val code = shownCode(rig)
        rig.controller.submitPairingCode(otherThan(code))

        assertFalse(rig.controller.state.value.toString().contains(code))
    }

    @Test
    fun aHostThatRefusesThePairingEndsTheSessionWithItsReason() = runTest {
        val rig = pairingRig(mac = ScriptedMac(alreadyPaired = false, refusal = "Another phone is pairing"))

        rig.controller.connect()
        settle()
        rig.controller.submitPairingCode(shownCode(rig))
        settle()

        assertEquals(
            SessionFailure.Handshake(FailureReason.PairingRefused("Another phone is pairing")),
            (rig.controller.state.value.phase as SessionPhase.Failed).reason,
        )
    }

    private fun shownCode(rig: ControllerRig): String = checkNotNull(rig.mac.connections.single().host.shownCode)

    private fun otherThan(code: String): String = if (code == "000000") "000001" else "000000"

    private fun TestScope.pairingRig(
        pins: FakePinStore = FakePinStore(),
        mac: ScriptedMac = ScriptedMac(alreadyPaired = false),
    ): ControllerRig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID), mac, pins)

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
