package pl.dmq.peering.session.flows

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.ApprovalAnswer
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.ToolStatus
import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentTurnSummary

class AgentTurnFlowTest {
    private val host = ScriptedAgentHost()

    @Test
    fun aTurnStreamsAnAskThatIsAllowedAndThenFinishes() {
        val link = AgentLink(host)
        host.queueTurn(firstTurn())

        startChatAndSend(link, "fix the build")
        assertEquals(AgentSessionState.AWAITING_APPROVAL, link.chat.state.value.selected?.state)
        assertEquals(listOf("ask-1"), link.chat.state.value.openApprovals.map { it.approvalID })

        link.chat.approve("ask-1", ApprovalAnswer.Allow)
        link.pump()

        assertTrue(link.chat.state.value.openApprovals.isEmpty())
        assertEquals(AgentSessionState.IDLE, link.chat.state.value.selected?.state)
        val rows = link.chat.state.value.transcriptRows
        assertEquals("fix the build", (rows.first() as TranscriptRow.User).text)
        assertEquals(ToolStatus.Ok, (rows.filterIsInstance<TranscriptRow.ToolCall>().single()).status)
        assertEquals(AgentTurnSummary(ok = true, stopped = false), (rows.last() as TranscriptRow.TurnSummary).summary)
        assertTrue(link.sent.contains(AgentRequest.Approval("S1", "ask-1", AgentApprovalDecision.Allow)))
    }

    @Test
    fun aPromptQueuedWhileTheTurnWaitsIsSentWhenTheTurnFinishes() {
        val link = AgentLink(host)
        host.queueTurn(firstTurn())
        host.queueTurn(
            listOf(
                AgentStreamPayload.TurnStarted,
                AgentStreamPayload.TextFinal("Tests pass."),
                AgentStreamPayload.TurnFinished(AgentTurnSummary(ok = true, stopped = false)),
            ),
        )
        startChatAndSend(link, "fix the build")

        link.chat.prompt("also run the tests")
        assertEquals(listOf("also run the tests"), link.chat.state.value.queuedPrompts)
        assertTrue(AgentRequest.Prompt("S1", "also run the tests") !in link.sent)

        link.chat.approve("ask-1", ApprovalAnswer.Allow)
        link.pump()

        assertEquals(emptyList<String>(), link.chat.state.value.queuedPrompts)
        assertEquals(AgentRequest.Prompt("S1", "also run the tests"), link.sent.last())
        assertEquals(AgentSessionState.IDLE, link.chat.state.value.selected?.state)
        assertTrue(link.chat.state.value.transcriptRows.any { it is TranscriptRow.AssistantText })
    }

    @Test
    fun interruptStopsARunningTurn() {
        val link = AgentLink(host)
        host.queueTurn(listOf(AgentStreamPayload.TurnStarted, AgentStreamPayload.TextDelta("Running the tests")))
        startChatAndSend(link, "run the tests")
        assertEquals(AgentSessionState.WORKING, link.chat.state.value.selected?.state)

        link.chat.interrupt()
        link.pump()

        assertEquals(AgentSessionState.IDLE, link.chat.state.value.selected?.state)
        val summary = (link.chat.state.value.transcriptRows.last() as TranscriptRow.TurnSummary).summary
        assertEquals(AgentTurnSummary(ok = false, stopped = true), summary)
        assertEquals(AgentRequest.Interrupt("S1"), link.sent.last())
    }

    @Test
    fun aReconnectReplaysTheTranscriptTheHostKept() {
        val first = AgentLink(host)
        host.queueTurn(firstTurn())
        startChatAndSend(first, "fix the build")
        first.chat.approve("ask-1", ApprovalAnswer.Allow)
        first.pump()
        val before = first.chat.state.value.transcriptRows

        val reconnected = AgentLink(host)
        reconnected.chat.list()
        reconnected.pump()

        assertEquals("S1", reconnected.chat.state.value.selectedSessionID)
        assertEquals(before, reconnected.chat.state.value.transcriptRows)
        assertEquals(AgentRequest.History("S1", since = 0), reconnected.sent.last())
    }

    /** Lists, starts a chat, and sends [prompt]; the turn stops at its first ask, which is "ask-1". */
    private fun startChatAndSend(link: AgentLink, prompt: String) {
        link.chat.list()
        link.pump()
        link.chat.start("claude", "/work")
        link.pump()
        link.chat.prompt(prompt)
        link.pump()
    }

    private fun firstTurn(): List<AgentStreamPayload> {
        val call = AgentToolCall(id = "t1", name = "Bash", title = "Run tests")
        return listOf(
            AgentStreamPayload.TurnStarted,
            AgentStreamPayload.TextDelta("Looking"),
            AgentStreamPayload.ToolStarted(call),
            AgentStreamPayload.ApprovalRequested("ask-1", call, reason = null),
            AgentStreamPayload.ToolFinished(callID = "t1", ok = true, output = "BUILD OK", truncated = false),
            AgentStreamPayload.TextFinal("The build passes."),
            AgentStreamPayload.TurnFinished(AgentTurnSummary(ok = true, stopped = false)),
        )
    }
}
