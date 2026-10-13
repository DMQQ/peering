package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentToolCall

class AgentChatAnswerTest {
    private val sent = mutableListOf<AgentRequest>()
    private val chat = AgentChat(AgentCapabilities(chat = true)) { sent += it }

    private fun info(id: String) = AgentSessionInfo(
        id = id, agentID = "claude", title = "Chat $id", directory = "/work",
        state = AgentSessionState.IDLE, lastIndex = 0, createdAt = 0.0,
    )

    private fun askInSecondChat() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        chat.onEvent(
            AgentEvent.Replay("B", listOf(AgentStreamEvent(1, AgentStreamPayload.TurnStarted)), isLast = true, truncatedAtFront = false),
        )
        chat.onEvent(
            AgentEvent.Stream("B", AgentStreamEvent(2, AgentStreamPayload.ApprovalRequested("ask-1", AgentToolCall("t", "Bash", "Run"), null))),
        )
        sent.clear()
    }

    @Test
    fun anAskInAChatThatIsNotSelectedCanBeAnswered() {
        askInSecondChat()
        assertEquals("A", chat.state.value.selectedSessionID)

        assertTrue(chat.answer("B", "ask-1", ApprovalAnswer.Deny))

        assertEquals(listOf<AgentRequest>(AgentRequest.Approval("B", "ask-1", AgentApprovalDecision.Deny)), sent)
    }

    @Test
    fun anAnswerForAnAskThatIsGoneIsNotSent() {
        askInSecondChat()
        chat.onEvent(AgentEvent.Stream("B", AgentStreamEvent(3, AgentStreamPayload.ApprovalResolved("ask-1", AgentApprovalDecision.Allow))))

        assertFalse(chat.answer("B", "ask-1", ApprovalAnswer.Allow))
        assertFalse(chat.answer("missing", "ask-1", ApprovalAnswer.Allow))
        assertEquals(emptyList<AgentRequest>(), sent)
    }

    @Test
    fun aHostWithoutChatSupportIsNeverAnswered() {
        val silent = AgentChat(AgentCapabilities()) { sent += it }
        assertFalse(silent.answer("B", "ask-1", ApprovalAnswer.Allow))
    }
}
