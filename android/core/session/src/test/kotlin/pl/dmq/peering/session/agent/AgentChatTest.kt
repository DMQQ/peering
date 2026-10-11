package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
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
import pl.dmq.peering.wire.AgentTurnSummary

class AgentChatTest {
    private val sent = mutableListOf<AgentRequest>()
    private val chat = AgentChat(supportsAgentChat = true) { sent += it }

    private fun info(id: String, state: AgentSessionState = AgentSessionState.IDLE) = AgentSessionInfo(
        id = id,
        agentID = "claude",
        title = "Chat $id",
        directory = "/work",
        state = state,
        lastIndex = 0,
        createdAt = 0.0,
    )

    private fun live(sessionID: String, index: Long, payload: AgentStreamPayload) =
        AgentEvent.Stream(sessionID, AgentStreamEvent(index, payload))

    private fun call(id: String) = AgentToolCall(id = id, name = "Bash", title = "Run tests")

    private val summary = AgentTurnSummary(ok = true, stopped = false)

    @Test
    fun aChatSendsNothingWithoutTheHostsSupport() {
        val silent = AgentChat(supportsAgentChat = false) { sent += it }
        silent.list()
        silent.start("claude", "/work")
        silent.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        silent.select("B")
        silent.prompt("hello")
        assertEquals(emptyList<AgentRequest>(), sent)
        assertEquals("A", silent.state.value.selectedSessionID)
    }

    @Test
    fun theSnapshotSelectsTheFirstChatAndAsksForItsHistory() {
        chat.list()
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        assertEquals("A", chat.state.value.selectedSessionID)
        assertEquals(listOf(AgentRequest.ListSessions, AgentRequest.History("A", since = 0)), sent)
    }

    @Test
    fun selectingAChatAskForItsHistoryOnlyOnce() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        sent.clear()
        chat.select("B")
        chat.select("B")
        assertEquals(listOf(AgentRequest.History("B", since = 0)), sent)
        assertEquals("B", chat.state.value.selectedSessionID)
    }

    @Test
    fun aLoadedChatDoesNotAskForItsHistoryAgain() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"))))
        chat.onEvent(AgentEvent.Replay("A", listOf(AgentStreamEvent(1, AgentStreamPayload.TurnStarted)), isLast = true, truncatedAtFront = false))
        sent.clear()
        chat.select("A")
        assertEquals(emptyList<AgentRequest>(), sent)
    }

    @Test
    fun aGapInTheStreamAsksForHistorySinceTheLastIndexHeld() {
        chat.onEvent(AgentEvent.Created(info("A")))
        chat.onEvent(AgentEvent.Replay("A", listOf(AgentStreamEvent(1, AgentStreamPayload.TurnStarted)), isLast = true, truncatedAtFront = false))
        sent.clear()
        chat.onEvent(live("A", 5, AgentStreamPayload.TextDelta("late")))
        chat.onEvent(live("A", 6, AgentStreamPayload.TextDelta("later")))
        assertEquals(listOf(AgentRequest.History("A", since = 1)), sent)
    }

    @Test
    fun aReplayFromIndexOneReplacesTheTranscriptRatherThanDoublingIt() {
        chat.onEvent(AgentEvent.Created(info("A")))
        chat.onEvent(AgentEvent.Replay("A", listOf(AgentStreamEvent(1, AgentStreamPayload.UserPrompt("first"))), isLast = true, truncatedAtFront = false))
        chat.onEvent(AgentEvent.Replay("A", listOf(AgentStreamEvent(1, AgentStreamPayload.UserPrompt("first"))), isLast = true, truncatedAtFront = false))
        assertEquals(1, chat.state.value.transcriptRows.size)
    }

    @Test
    fun aClosedChatLeavesTheListAndSelectionMovesToTheFirstRemaining() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        chat.onEvent(AgentEvent.Closed("A"))
        assertEquals(listOf("B"), chat.state.value.sessions.map { it.id })
        assertEquals("B", chat.state.value.selectedSessionID)
    }

    @Test
    fun aFailureNamingNoChatIsShownForTheWholeList() {
        chat.onEvent(AgentEvent.Failed(message = "Mac is busy"))
        assertEquals("Mac is busy", chat.state.value.failure)
    }

    @Test
    fun aFailureNamingAChatIsShownOnThatChat() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"))))
        chat.onEvent(AgentEvent.Failed(sessionID = "A", message = "CLI exited"))
        assertEquals("CLI exited", chat.state.value.selected?.failure)
        assertEquals(null, chat.state.value.failure)
    }

    @Test
    fun aPromptIsDroppedWhenBlank() {
        chat.onEvent(AgentEvent.Created(info("A")))
        sent.clear()
        chat.prompt("   ")
        assertEquals(emptyList<AgentRequest>(), sent)
    }

    @Test
    fun anAnswerForAnAskThatIsNotPendingIsNotSent() {
        chat.onEvent(AgentEvent.Created(info("A")))
        sent.clear()
        chat.approve("nobody", ApprovalAnswer.Allow)
        assertEquals(emptyList<AgentRequest>(), sent)
    }

    @Test
    fun aTurnRunsFromStartToAQueuedPromptBeingReleased() {
        chat.list()
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"))))
        chat.start("claude", "/work")
        chat.onEvent(AgentEvent.Created(info("B")))
        chat.onEvent(AgentEvent.Replay("B", listOf(AgentStreamEvent(1, AgentStreamPayload.SessionReady("claude", directory = "/work"))), isLast = true, truncatedAtFront = false))

        chat.prompt("fix the build")
        assertEquals(AgentSessionState.WORKING, chat.state.value.selected?.state)

        chat.onEvent(live("B", 2, AgentStreamPayload.TurnStarted))
        chat.onEvent(live("B", 3, AgentStreamPayload.TextDelta("Looking")))
        chat.onEvent(live("B", 4, AgentStreamPayload.ApprovalRequested("ask-1", call("t1"), reason = null)))
        assertEquals(listOf("ask-1"), chat.state.value.openApprovals.map { it.approvalID })
        assertEquals(AgentSessionState.AWAITING_APPROVAL, chat.state.value.selected?.state)

        chat.prompt("also run the tests")
        assertEquals(listOf("also run the tests"), chat.state.value.queuedPrompts)

        chat.approve("ask-1", ApprovalAnswer.Allow)
        chat.onEvent(live("B", 5, AgentStreamPayload.ApprovalResolved("ask-1", AgentApprovalDecision.Allow)))
        assertTrue(chat.state.value.openApprovals.isEmpty())

        chat.onEvent(live("B", 6, AgentStreamPayload.TurnFinished(summary)))
        assertEquals(emptyList<String>(), chat.state.value.queuedPrompts)

        assertEquals(
            listOf(
                AgentRequest.ListSessions,
                AgentRequest.History("A", since = 0),
                AgentRequest.Start("claude", "/work"),
                AgentRequest.History("B", since = 0),
                AgentRequest.Prompt("B", "fix the build"),
                AgentRequest.Approval("B", "ask-1", AgentApprovalDecision.Allow),
                AgentRequest.Prompt("B", "also run the tests"),
            ),
            sent,
        )
    }

    @Test
    fun aPromptTypedAfterAnIdleChatSendsAtOnce() {
        chat.onEvent(AgentEvent.Created(info("A")))
        chat.prompt("hello")
        assertEquals(AgentRequest.Prompt("A", "hello"), sent.last())
    }

    @Test
    fun interruptAndCloseTargetTheSelectedChat() {
        chat.onEvent(AgentEvent.Snapshot(listOf(info("A"), info("B"))))
        sent.clear()
        chat.select("B")
        chat.interrupt()
        chat.close()
        assertEquals(
            listOf(AgentRequest.History("B", since = 0), AgentRequest.Interrupt("B"), AgentRequest.Close("B")),
            sent,
        )
    }
}
