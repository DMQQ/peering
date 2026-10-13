package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentTurnSummary

class AgentFollowUpsTest {
    private val summary = TranscriptRow.TurnSummary(9, AgentTurnSummary(ok = true, stopped = false))

    private fun user() = TranscriptRow.User(1, "do it")

    private fun tool(name: String, status: ToolStatus = ToolStatus.Ok, detail: String? = null, diff: String? = null) =
        TranscriptRow.ToolCall(2, AgentToolCall(id = "c", name = name, title = name, detail = detail, diff = diff), status, null, truncated = false)

    @Test
    fun `an edit offers review, tests and summary`() {
        val rows = listOf(user(), tool("Edit"), summary)

        assertEquals(listOf(FollowUp.REVIEW_CHANGES, FollowUp.RUN_TESTS, FollowUp.SUMMARIZE_CHANGES), AgentFollowUps.suggestions(rows, working = false))
    }

    @Test
    fun `a turn that already ran tests does not offer to run them`() {
        val rows = listOf(user(), tool("Edit"), tool("Bash", detail = "swift test"), summary)

        assertEquals(listOf(FollowUp.REVIEW_CHANGES, FollowUp.SUMMARIZE_CHANGES), AgentFollowUps.suggestions(rows, working = false))
    }

    @Test
    fun `a diff alone counts as an edit`() {
        val rows = listOf(user(), tool("Patch", diff = "@@ -1 +1 @@"), summary)

        assertEquals(3, AgentFollowUps.suggestions(rows, working = false).size)
    }

    @Test
    fun `nothing while working, after a question, after a failed edit, or without a finished turn`() {
        assertEquals(emptyList<FollowUp>(), AgentFollowUps.suggestions(listOf(user(), tool("Edit"), summary), working = true))
        assertEquals(emptyList<FollowUp>(), AgentFollowUps.suggestions(listOf(user(), tool("Read"), summary), working = false))
        assertEquals(emptyList<FollowUp>(), AgentFollowUps.suggestions(listOf(user(), tool("Edit", ToolStatus.Failed), summary), working = false))
        assertEquals(emptyList<FollowUp>(), AgentFollowUps.suggestions(listOf(user(), tool("Edit")), working = false))
    }

    @Test
    fun `an edit in an earlier turn does not count`() {
        val rows = listOf(user(), tool("Edit"), summary, TranscriptRow.User(10, "what is this?"), TranscriptRow.AssistantText(11, "a thing"), summary.copy(id = 12))

        assertEquals(emptyList<FollowUp>(), AgentFollowUps.suggestions(rows, working = false))
    }
}
