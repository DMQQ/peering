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
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.ErrorPayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.WireJson

class ReconnectSessionTest {
    @Test
    fun aSilentHostIsRedialledAlongTheLadderAndResumesTheChosenSource() = runTest {
        val mac = ScriptedMac()
        val rig = lanRig(mac)
        mac.answersPings = false
        rig.controller.connect()
        settle()
        rig.controller.chooseSource(CaptureSource.Display(7))

        advanceTimeBy(3_000)
        runCurrent()
        assertEquals(1, mac.connections.size)
        advanceTimeBy(300)
        runCurrent()
        assertEquals(SessionPhase.Reconnecting(1), rig.controller.state.value.phase)

        mac.answersPings = true
        advanceTimeBy(500)
        runCurrent()

        assertEquals(2, mac.connections.size)
        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        val resumed = mac.connections[1].phoneFrames.clientHellos().single()
        assertEquals(CaptureSource.Display(7).toJson(), resumed.resumeSource)
    }

    @Test
    fun aHostThatNeverAnswersAgainEndsAsConnectionLostAfterTheLadderIsSpent() = runTest {
        val mac = ScriptedMac()
        val rig = lanRig(mac)
        rig.controller.connect()
        settle()
        mac.answersPings = false
        rig.reachable = false

        advanceTimeBy(40_000)
        runCurrent()

        assertEquals(
            SessionPhase.Failed(SessionFailure.ConnectionLost, canRetry = true),
            rig.controller.state.value.phase,
        )
        assertEquals(SessionRecord.EndReason.CONNECTION_LOST, rig.history.records.single().reason)
    }

    @Test
    fun aHostStoppedErrorEndsTheSessionWithoutReconnecting() = runTest {
        val mac = ScriptedMac()
        val rig = lanRig(mac)
        rig.controller.connect()
        settle()

        mac.connections.single().deliver(
            Frame(
                MessageKind.Error,
                WireJson.encodeToString(ErrorPayload.serializer(), ErrorPayload(ErrorPayload.HOST_STOPPED_CODE, "stopped"))
                    .toByteArray(Charsets.UTF_8),
            ),
        )
        runCurrent()
        advanceTimeBy(60_000)
        runCurrent()

        assertEquals(SessionPhase.Ended, rig.controller.state.value.phase)
        assertEquals(1, mac.connections.size)
        assertEquals(SessionRecord.EndReason.HOST_STOPPED, rig.history.records.single().reason)
    }

    private fun TestScope.lanRig(mac: ScriptedMac): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID),
        mac,
    )

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
