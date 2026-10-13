package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ApprovalStatus
import pl.dmq.peering.session.agent.ToolStatus
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentToolCall

class ChatTabsAndSubagentsTest {
    private fun session(id: String, title: String = id, state: AgentSessionState = AgentSessionState.IDLE, renamed: String? = null) =
        AgentChatSession(
            info = AgentSessionInfo(id = id, agentID = "claude", title = title, directory = "/d", state = state, lastIndex = 0, createdAt = 0.0),
            renamedTo = renamed,
        )

    @Test
    fun `a lone chat has no tab strip`() {
        assertTrue(ChatTab.of(AgentChatState(sessions = listOf(session("A")), selectedSessionID = "A")).isEmpty())
    }

    @Test
    fun `each open chat is a tab with the selected one marked and a phone side name winning`() {
        val tabs = ChatTab.of(
            AgentChatState(
                sessions = listOf(session("A", "first"), session("B", "second", AgentSessionState.WORKING, renamed = "mine")),
                selectedSessionID = "B",
            ),
        )

        assertEquals(listOf("first", "mine"), tabs.map { it.title })
        assertEquals(listOf(false, true), tabs.map { it.selected })
        assertEquals(AgentSessionState.WORKING, tabs[1].state)
    }

    @Test
    fun `a sub-agent takes its title from the task call that started it and shows what it did`() {
        val call = AgentToolCall(id = "task-1", name = "Task", title = "Task", detail = "Find the bug")
        val inner = TranscriptState(
            rows = listOf(TranscriptRow.AssistantText(1, "looking"), TranscriptRow.Approval(2, "ap", call, null, ApprovalStatus.Pending)),
            sessionState = AgentSessionState.WORKING,
        )
        val rows = listOf(
            TranscriptRow.ToolCall(1, call, ToolStatus.Running, null, truncated = false),
            TranscriptRow.Subagent(2, "task-1", inner),
        )

        val view = SubagentView.of(rows).single()

        assertEquals("task-1", view.callID)
        assertEquals("Find the bug", view.title)
        assertTrue(view.working)
        assertEquals(1, view.rows.size)
    }

    @Test
    fun `a sub-agent without its call has no title and one that finished is not working`() {
        val inner = TranscriptState(sessionState = AgentSessionState.IDLE)

        val view = SubagentView.of(listOf(TranscriptRow.Subagent(1, "gone", inner))).single()

        assertEquals(null, view.title)
        assertEquals(false, view.working)
    }
}
