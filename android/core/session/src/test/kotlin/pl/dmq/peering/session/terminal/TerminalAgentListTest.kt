package pl.dmq.peering.session.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo

class TerminalAgentListTest {
    private val sent = mutableListOf<TerminalRequest>()

    private fun sessions() = TerminalSessions(send = { sent += it })

    @Test
    fun theComputerIsAskedForItsAgentList() {
        val sessions = sessions()
        sessions.refreshAgents()
        assertEquals(listOf(TerminalRequest.ListAgents), sent)
        assertTrue(sessions.state.value.agentListPending)
    }

    @Test
    fun theAnswerIsKeptAndSurvivesARelist() {
        val sessions = sessions()
        assertNull(sessions.state.value.installedAgents)
        sessions.refreshAgents()
        sessions.onEvent(TerminalEvent.Agents(listOf("claude", "codex")))
        sessions.onEvent(TerminalEvent.Snapshot(listOf(TerminalSessionInfo("a", "a", true, null, null))))
        assertEquals(setOf("claude", "codex"), sessions.state.value.installedAgents)
        assertFalse(sessions.state.value.agentListPending)
    }
}
