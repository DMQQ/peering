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

    private fun sessions(supported: Boolean) = TerminalSessions(send = { sent += it }, listsAgents = { supported })

    @Test
    fun aComputerThatDeclaredTheListIsAskedForIt() {
        val sessions = sessions(supported = true)
        sessions.refreshAgents()
        assertEquals(listOf(TerminalRequest.ListAgents), sent)
        assertTrue(sessions.state.value.agentListPending)
    }

    @Test
    fun aComputerThatDidNotDeclareTheListIsNeverAsked() {
        val sessions = sessions(supported = false)
        sessions.refreshAgents()
        assertTrue(sent.isEmpty())
        assertFalse(sessions.state.value.agentListPending)
    }

    @Test
    fun theAnswerIsKeptAndSurvivesARelist() {
        val sessions = sessions(supported = true)
        assertNull(sessions.state.value.installedAgents)
        sessions.refreshAgents()
        sessions.onEvent(TerminalEvent.Agents(listOf("claude", "codex")))
        sessions.onEvent(TerminalEvent.Snapshot(listOf(TerminalSessionInfo("a", "a", true, null, null))))
        assertEquals(setOf("claude", "codex"), sessions.state.value.installedAgents)
        assertFalse(sessions.state.value.agentListPending)
    }
}
