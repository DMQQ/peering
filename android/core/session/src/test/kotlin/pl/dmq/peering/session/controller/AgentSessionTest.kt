@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind

class AgentSessionTest {
    @Test
    fun anAgentChatIsOfferedAndItsRequestsAreSentWhenTheHostDeclaresIt() = runTest {
        val mac = ScriptedMac(declare = { it.copy(supportsAgentChat = true) })
        val rig = lanRig(mac)
        rig.controller.connect()
        settle()

        val chat = checkNotNull(rig.controller.agentChat)
        chat.list()
        settle()
        assertTrue(mac.connections.single().phoneFrames.ofKind(MessageKind.AgentRequest).isNotEmpty())

        mac.connections.single().deliver(Frame(MessageKind.AgentEvent, AgentEvent.Snapshot(listOf(SESSION)).toJson().toByteArray()))
        settle()
        assertEquals(listOf(SESSION.id), chat.state.value.sessions.map { it.id })
    }

    @Test
    fun withoutTheDeclarationThereIsNoAgentChatAndNothingIsSent() = runTest {
        val mac = ScriptedMac()
        val rig = lanRig(mac)
        rig.controller.connect()
        settle()

        assertNull(rig.controller.agentChat)
        assertTrue(mac.connections.single().phoneFrames.ofKind(MessageKind.AgentRequest).isEmpty())
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

    private companion object {
        val SESSION = AgentSessionInfo(
            id = "session-1",
            agentID = "claude",
            title = "Refactor",
            directory = "/Users/me/app",
            state = AgentSessionState.IDLE,
            lastIndex = 0,
            permissionMode = AgentPermissionMode.MANUAL,
            createdAt = 0.0,
        )
    }
}
