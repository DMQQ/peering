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
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind

class FrameRouterUnknownCaseTest {
    @Test
    fun anUnknownAgentTerminalOrPreviewCaseLeavesTheSessionUpAndLaterEventsStillLand() = runTest {
        val mac = ScriptedMac(declare = { it.copy(supportsAgentChat = true) })
        val rig = ControllerRig(
            backgroundScope,
            testScheduler,
            ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID),
            mac,
        )
        rig.controller.connect()
        settle()
        val connection = mac.connections.single()

        connection.deliver(Frame(MessageKind.AgentEvent, """{"someFutureCase":{"_0":"x"}}""".toByteArray()))
        connection.deliver(Frame(MessageKind.TerminalEvent, """{"someFutureCase":{"_0":"x"}}""".toByteArray()))
        connection.deliver(Frame(MessageKind.PreviewEvent, """{"someFutureCase":{"_0":"x"}}""".toByteArray()))
        connection.deliver(Frame(MessageKind.AgentEvent, AgentEvent.Snapshot(listOf(SESSION)).toJson().toByteArray()))
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertEquals(1, mac.connections.size)
        assertEquals(listOf(SESSION.id), checkNotNull(rig.controller.agentChat).state.value.sessions.map { it.id })
    }

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }

    private companion object {
        val SESSION = AgentSessionInfo(
            id = "session-1",
            agentID = "claude",
            title = "Refactor",
            directory = "/Users/me/app",
            state = AgentSessionState.IDLE,
            lastIndex = 0,
            createdAt = 0.0,
        )
    }
}
