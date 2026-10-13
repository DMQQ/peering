@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PairConfirm
import pl.dmq.peering.wire.WireJson

/** A pairing that loses its host, or is walked away from, ends in a state the screen can leave. */
class PairingEndsTest {
    /** The points of a pairing at which the phone is waiting, named by the frame the host does not send next. */
    private enum class Step(val hostStaysQuietOn: MessageKind?) {
        ServerHello(MessageKind.ClientHello),
        ServerCommit(MessageKind.PairCommit),
        ServerReveal(MessageKind.PairReveal),
        EnteringCode(null),
        PairResult(MessageKind.PairConfirm),
    }

    private val pastEveryLimit = 130_000L

    @Test
    fun aHostThatClosesAtAnyStepFailsThePairingAtOnce() = runTest {
        for (step in Step.entries) {
            val rig = rigAt(step, closes = true)

            if (step == Step.EnteringCode) rig.mac.connections.single().hostCloses()
            advanceTimeBy(1_000)
            runCurrent()

            assertClosedFailure(rig, step)
        }
    }

    @Test
    fun aHostThatGoesSilentAtAnyStepFailsThePairingOnceItsLimitPasses() = runTest {
        for (step in Step.entries) {
            val rig = rigAt(step, closes = false)
            advanceTimeBy(5_000)
            runCurrent()
            assertTrue("$step ended too early", rig.controller.state.value.phase !is SessionPhase.Failed)

            advanceTimeBy(pastEveryLimit)
            runCurrent()

            assertClosedFailure(rig, step)
        }
    }

    @Test
    fun cancellingAtAnyStepEndsTheSessionAndTellsTheHostOnlyWhenItWaitsOnThePhone() = runTest {
        for (step in Step.entries) {
            val rig = rigAt(step, closes = false)

            rig.controller.disconnect()
            runCurrent()
            advanceTimeBy(1_000)
            runCurrent()

            val connection = rig.mac.connections.single()
            assertEquals("$step", SessionPhase.Ended, rig.controller.state.value.phase)
            assertTrue("$step left the connection open", connection.closed)
            val declines = connection.phoneFrames.filter { it.kind == MessageKind.PairConfirm }.map {
                WireJson.decodeFromString(PairConfirm.serializer(), it.payload.decodeToString()).accepted
            }
            val expected = when (step) {
                Step.EnteringCode -> listOf(false)
                Step.PairResult -> listOf(true, false)
                else -> emptyList()
            }
            assertEquals("$step", expected, declines)
            assertNull(rig.pins.pin(ScriptedPairingHost.HOST_ID))
        }
    }

    @Test
    fun aHostThatDeclinesTheApprovalFailsThePairingWithItsReason() = runTest {
        val rig = pairingRig(ScriptedMac(alreadyPaired = false, refusal = "Declined on the Mac"))
        rig.controller.connect()
        settle()
        rig.controller.submitPairingCode(checkNotNull(rig.mac.connections.single().host.shownCode))
        settle()

        assertEquals(
            SessionPhase.Failed(SessionFailure.Handshake(FailureReason.PairingRefused("Declined on the Mac")), canRetry = true),
            rig.controller.state.value.phase,
        )
        assertTrue(rig.mac.connections.single().closed)
    }

    @Test
    fun aPairingThatEndedNeverLeavesThePairingPhasesBehind() = runTest {
        val pairingPhases = { phase: SessionPhase -> phase is SessionPhase.Connecting || phase is SessionPhase.EnteringPairingCode }
        for (step in Step.entries) {
            for (ending in listOf("closed", "silent", "cancelled")) {
                val rig = rigAt(step, closes = false)
                when (ending) {
                    "closed" -> rig.mac.connections.single().hostCloses()
                    "silent" -> advanceTimeBy(pastEveryLimit)
                    else -> rig.controller.disconnect()
                }
                advanceTimeBy(pastEveryLimit)
                runCurrent()

                assertFalse("$step $ending", pairingPhases(rig.controller.state.value.phase))
            }
        }
    }

    private fun assertClosedFailure(rig: ControllerRig, step: Step) {
        val phase = rig.controller.state.value.phase
        assertTrue("$step ended as $phase", phase is SessionPhase.Failed)
        val failure = (phase as SessionPhase.Failed).reason
        assertTrue("$step failed as $failure", failure is SessionFailure.ConnectionFailed && failure.kind == ConnectFailureKind.Closed)
        assertTrue(phase.canRetry)
        assertTrue("$step left the connection open", rig.mac.connections.single().closed)
    }

    private suspend fun TestScope.rigAt(step: Step, closes: Boolean): ControllerRig {
        val mac = ScriptedMac(alreadyPaired = false)
        val rig = pairingRig(mac)
        if (closes) mac.dropsOn = step.hostStaysQuietOn else mac.silentOn = step.hostStaysQuietOn
        rig.controller.connect()
        settle()
        if (step == Step.PairResult) {
            rig.controller.submitPairingCode(checkNotNull(mac.connections.single().host.shownCode))
            settle()
        }
        return rig
    }

    private fun TestScope.pairingRig(mac: ScriptedMac): ControllerRig =
        ControllerRig(backgroundScope, testScheduler, ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID), mac, FakePinStore())

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
