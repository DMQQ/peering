package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentPlanStep
import pl.dmq.peering.wire.AgentPlanStepStatus
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentTurnSummary

class TranscriptReducerTest {
    private fun fold(vararg payloads: AgentStreamPayload): TranscriptState {
        val events = payloads.mapIndexed { position, payload -> AgentStreamEvent(position + 1L, payload) }
        return events.fold(TranscriptState()) { state, event -> TranscriptReducer.reduce(state, event) }
    }

    private fun call(id: String, plan: List<AgentPlanStep>? = null) =
        AgentToolCall(id = id, name = "Bash", title = "Run", detail = "ls", plan = plan)

    private val summary = AgentTurnSummary(ok = true, stopped = false)

    @Test
    fun userPromptAddsAUserRow() {
        val state = fold(AgentStreamPayload.UserPrompt("fix it"))
        assertEquals(listOf<TranscriptRow>(TranscriptRow.User(1, "fix it")), state.rows)
    }

    @Test
    fun textDeltasBuildOneReplyThatTextFinalReplaces() {
        val state = fold(
            AgentStreamPayload.TextDelta("Hel"),
            AgentStreamPayload.TextDelta("lo"),
        )
        assertEquals(listOf<TranscriptRow>(TranscriptRow.AssistantText(1, "Hello")), state.rows)
        assertEquals(AgentSessionState.WORKING, state.sessionState)

        val final = TranscriptReducer.reduce(state, AgentStreamEvent(3, AgentStreamPayload.TextFinal("Hello there")))
        assertEquals(listOf<TranscriptRow>(TranscriptRow.AssistantText(1, "Hello there")), final.rows)
    }

    @Test
    fun textFinalWithoutDeltasAddsAReply() {
        val state = fold(AgentStreamPayload.TextFinal("Done"))
        assertEquals(listOf<TranscriptRow>(TranscriptRow.AssistantText(1, "Done")), state.rows)
    }

    @Test
    fun aUserPromptClosesTheOpenReply() {
        val state = fold(
            AgentStreamPayload.TextDelta("one"),
            AgentStreamPayload.UserPrompt("two"),
            AgentStreamPayload.TextDelta("three"),
        )
        assertEquals(
            listOf<TranscriptRow>(
                TranscriptRow.AssistantText(1, "one"),
                TranscriptRow.User(2, "two"),
                TranscriptRow.AssistantText(3, "three"),
            ),
            state.rows,
        )
    }

    @Test
    fun toolStartedThenFinishedCarriesItsResult() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("t1")),
            AgentStreamPayload.ToolFinished("t1", ok = true, output = "a.txt", truncated = false),
        )
        val tool = state.rows.single() as TranscriptRow.ToolCall
        assertEquals(ToolStatus.Ok, tool.status)
        assertEquals("a.txt", tool.output)
    }

    @Test
    fun aFailedToolFinishMarksTheCallFailed() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("t1")),
            AgentStreamPayload.ToolFinished("t1", ok = false, output = null, truncated = false),
        )
        assertEquals(ToolStatus.Failed, (state.rows.single() as TranscriptRow.ToolCall).status)
    }

    @Test
    fun aSecondFinishWithoutOutputKeepsTheFirstOutput() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("t1")),
            AgentStreamPayload.ToolFinished("t1", ok = true, output = "first", truncated = true),
            AgentStreamPayload.ToolFinished("t1", ok = true, output = null, truncated = false),
        )
        val tool = state.rows.single() as TranscriptRow.ToolCall
        assertEquals("first", tool.output)
        assertTrue(tool.truncated)
    }

    @Test
    fun aFinishForAnUnknownCallIsIgnored() {
        val state = fold(AgentStreamPayload.ToolFinished("nope", ok = true, output = "x", truncated = false))
        assertTrue(state.rows.isEmpty())
    }

    @Test
    fun aPlanFromToolsReplacesOneRowInPlace() {
        val first = listOf(AgentPlanStep("Read", AgentPlanStepStatus.IN_PROGRESS))
        val second = listOf(AgentPlanStep("Read", AgentPlanStepStatus.COMPLETED))
        val state = fold(
            AgentStreamPayload.ToolStarted(call("t1", first)),
            AgentStreamPayload.ToolStarted(call("t2", second)),
        )
        val plans = state.rows.filterIsInstance<TranscriptRow.Plan>()
        assertEquals(listOf(TranscriptRow.Plan(1, second)), plans)
    }

    @Test
    fun approvalRequestMarksTheToolAndAddsAPendingRow() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("t1")),
            AgentStreamPayload.ApprovalRequested("ap1", call("t1"), reason = "needs approval"),
        )
        assertEquals(ToolStatus.AwaitingApproval("ap1"), (state.rows[0] as TranscriptRow.ToolCall).status)
        val approval = state.rows[1] as TranscriptRow.Approval
        assertEquals("ap1", approval.approvalID)
        assertEquals(ApprovalStatus.Pending, approval.status)
        assertEquals(AgentSessionState.AWAITING_APPROVAL, state.sessionState)
    }

    @Test
    fun anApprovalForANewCallAddsItsToolRow() {
        val state = fold(AgentStreamPayload.ApprovalRequested("ap1", call("t9"), reason = null))
        assertEquals(ToolStatus.AwaitingApproval("ap1"), (state.rows[0] as TranscriptRow.ToolCall).status)
    }

    @Test
    fun allowResumesTheToolAndDenyStopsIt() {
        val asked = listOf(
            AgentStreamPayload.ToolStarted(call("t1")),
            AgentStreamPayload.ApprovalRequested("ap1", call("t1"), reason = null),
        )
        val allowed = fold(*asked.toTypedArray(), AgentStreamPayload.ApprovalResolved("ap1", AgentApprovalDecision.Allow))
        assertEquals(ToolStatus.Running, (allowed.rows[0] as TranscriptRow.ToolCall).status)
        assertEquals(AgentSessionState.WORKING, allowed.sessionState)

        val denied = fold(*asked.toTypedArray(), AgentStreamPayload.ApprovalResolved("ap1", AgentApprovalDecision.Deny))
        assertEquals(ToolStatus.Denied, (denied.rows[0] as TranscriptRow.ToolCall).status)
    }

    @Test
    fun aChoiceIsAnAllowWithAPayloadSoTheToolRuns() {
        val state = fold(
            AgentStreamPayload.ApprovalRequested("ap1", call("t1"), reason = null),
            AgentStreamPayload.ApprovalResolved("ap1", AgentApprovalDecision.Choose(listOf("Postgres"))),
        )
        assertEquals(ToolStatus.Running, (state.rows[0] as TranscriptRow.ToolCall).status)
        val approval = state.rows[1] as TranscriptRow.Approval
        assertEquals(ApprovalStatus.Answered(AgentApprovalDecision.Choose(listOf("Postgres"))), approval.status)
    }

    @Test
    fun turnFinishedCancelsOpenAsksAndAddsItsSummary() {
        val state = fold(
            AgentStreamPayload.ApprovalRequested("ap1", call("t1"), reason = null),
            AgentStreamPayload.TurnFinished(summary),
        )
        assertEquals(ApprovalStatus.Cancelled, (state.rows[1] as TranscriptRow.Approval).status)
        assertEquals(TranscriptRow.TurnSummary(3, summary), state.rows.last())
        assertEquals(AgentSessionState.IDLE, state.sessionState)
    }

    @Test
    fun failureAndExitSetTheSessionState() {
        val failed = fold(AgentStreamPayload.Failure("boom"))
        assertEquals(listOf<TranscriptRow>(TranscriptRow.Failure(1, "boom")), failed.rows)
        assertEquals(AgentSessionState.FAILED, failed.sessionState)
        assertEquals(AgentSessionState.EXITED, fold(AgentStreamPayload.SessionExited(0)).sessionState)
    }

    @Test
    fun noticeAddsARowWithoutChangingTheState() {
        val state = fold(AgentStreamPayload.Notice("Resumed"))
        assertEquals(listOf<TranscriptRow>(TranscriptRow.Notice(1, "Resumed")), state.rows)
        assertEquals(AgentSessionState.IDLE, state.sessionState)
    }

    @Test
    fun childEventsNestUnderTheSpawningCall() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("task1")),
            AgentStreamPayload.Child("task1", AgentStreamPayload.TextDelta("sub work")),
        )
        val subagent = state.rows[1] as TranscriptRow.Subagent
        assertEquals("task1", subagent.parentCallID)
        assertEquals(listOf<TranscriptRow>(TranscriptRow.AssistantText(1, "sub work")), subagent.transcript.rows)
        assertEquals(AgentSessionState.WORKING, subagent.transcript.sessionState)
    }

    @Test
    fun finishingTheSpawningCallIdlesTheSubagent() {
        val state = fold(
            AgentStreamPayload.ToolStarted(call("task1")),
            AgentStreamPayload.Child("task1", AgentStreamPayload.TextDelta("sub work")),
            AgentStreamPayload.ToolFinished("task1", ok = true, output = "done", truncated = false),
        )
        assertEquals(AgentSessionState.IDLE, (state.rows[1] as TranscriptRow.Subagent).transcript.sessionState)
    }

    @Test
    fun aRepeatedIndexIsIgnored() {
        val first = TranscriptReducer.reduce(TranscriptState(), AgentStreamEvent(1, AgentStreamPayload.Notice("a")))
        val again = TranscriptReducer.reduce(first, AgentStreamEvent(1, AgentStreamPayload.Notice("b")))
        assertEquals(first, again)
    }

    @Test
    fun anEventPastAGapIsWithheldAndFlaggedForHistory() {
        val start = fold(AgentStreamPayload.Notice("one"), AgentStreamPayload.Notice("two"))
        val gapped = TranscriptReducer.reduce(start, AgentStreamEvent(5, AgentStreamPayload.Notice("five")))
        assertEquals(start.rows, gapped.rows)
        assertEquals(2L, gapped.lastIndex)
        assertTrue(gapped.needsHistory)
    }

    @Test
    fun aReplayFillsTheGapAndClearsTheFlagOnItsLastChunk() {
        val start = fold(AgentStreamPayload.Notice("one"), AgentStreamPayload.Notice("two"))
        val gapped = TranscriptReducer.reduce(start, AgentStreamEvent(4, AgentStreamPayload.Notice("four")))
        val history = listOf(
            AgentStreamEvent(3, AgentStreamPayload.Notice("three")),
            AgentStreamEvent(4, AgentStreamPayload.Notice("four")),
        )
        val partial = TranscriptReducer.replay(gapped, history.take(1), isLast = false, truncatedAtFront = false)
        assertTrue(partial.needsHistory)
        assertEquals(3L, partial.lastIndex)

        val complete = TranscriptReducer.replay(partial, history.drop(1), isLast = true, truncatedAtFront = false)
        assertFalse(complete.needsHistory)
        assertEquals(4L, complete.lastIndex)
        assertEquals(4, complete.rows.size)
    }

    @Test
    fun aReplayDoesNotDrawAnEventTwiceWhenALiveOneRacedIt() {
        val live = fold(AgentStreamPayload.Notice("one"), AgentStreamPayload.Notice("two"))
        val replayed = TranscriptReducer.replay(
            live,
            listOf(AgentStreamEvent(1, AgentStreamPayload.Notice("one")), AgentStreamEvent(2, AgentStreamPayload.Notice("two"))),
            isLast = true,
            truncatedAtFront = false,
        )
        assertEquals(live, replayed)
    }

    @Test
    fun aReplayKeepsTheMacsTruncationFlag() {
        val state = TranscriptReducer.replay(TranscriptState(), emptyList(), isLast = true, truncatedAtFront = true)
        assertTrue(state.truncatedAtFront)
    }

    @Test
    fun anOverBudgetTranscriptDropsItsOldestTurnsAndSaysSo() {
        val big = "x".repeat(300_000)
        val state = fold(
            AgentStreamPayload.UserPrompt("first"),
            AgentStreamPayload.TextFinal(big),
            AgentStreamPayload.UserPrompt("second"),
            AgentStreamPayload.TextFinal(big),
        )
        assertTrue(state.truncatedAtFront)
        assertEquals(TranscriptRow.User(3, "second"), state.rows.first())
    }
}
