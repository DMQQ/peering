package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentApprovalDecision
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentStreamEvent
import pl.dmq.peering.wire.AgentStreamPayload
import pl.dmq.peering.wire.AgentToolCall
import pl.dmq.peering.wire.AgentTurnSummary

class ApprovalsTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"
    private val bash = AgentToolCall(id = "t1", name = "Bash", title = "Run", detail = "rm build")

    private fun transcript(vararg payloads: AgentStreamPayload): TranscriptState =
        payloads.mapIndexed { position, payload -> AgentStreamEvent(position + 1L, payload) }
            .fold(TranscriptState()) { state, event -> TranscriptReducer.reduce(state, event) }

    @Test
    fun anAskTheMacRaisedIsPendingUntilItIsResolved() {
        val state = transcript(AgentStreamPayload.ApprovalRequested("ap1", bash, reason = "destructive"))
        assertEquals(listOf(PendingApproval("ap1", bash, "destructive")), pendingApprovals(state.rows))
    }

    @Test
    fun anAskResolvedElsewhereIsRemovedFromPending() {
        val state = transcript(
            AgentStreamPayload.ApprovalRequested("ap1", bash, reason = null),
            AgentStreamPayload.ApprovalResolved("ap1", AgentApprovalDecision.Allow),
        )
        assertTrue(pendingApprovals(state.rows).isEmpty())
    }

    @Test
    fun aFinishedTurnLeavesNothingPending() {
        val state = transcript(
            AgentStreamPayload.ApprovalRequested("ap1", bash, reason = null),
            AgentStreamPayload.TurnFinished(AgentTurnSummary(ok = false, stopped = true)),
        )
        assertTrue(pendingApprovals(state.rows).isEmpty())
    }

    @Test
    fun allowDenyAndChooseBecomeTheirWireDecisions() {
        assertEquals(AgentApprovalDecision.Allow, ApprovalAnswer.Allow.toDecision())
        assertEquals(AgentApprovalDecision.Deny, ApprovalAnswer.Deny.toDecision())
        assertEquals(
            AgentApprovalDecision.Choose(listOf("Postgres", "Yes")),
            ApprovalAnswer.Choose(listOf("Postgres", "Yes")).toDecision(),
        )
    }

    @Test
    fun aPendingAskIsAnsweredWithItsIdAndTheChosenDecision() {
        val pending = listOf(PendingApproval("ap2", bash, null))
        val request = answerRequest(sessionID, pending, "ap2", ApprovalAnswer.Choose(listOf("Postgres")))
        assertEquals(AgentRequest.Approval(sessionID, "ap2", AgentApprovalDecision.Choose(listOf("Postgres"))), request)
    }

    @Test
    fun anAnswerForAnAskThatIsNoLongerPendingBuildsNothing() {
        assertNull(answerRequest(sessionID, emptyList(), "ap1", ApprovalAnswer.Allow))
    }

    @Test
    fun aSecondAnswerAfterTheFirstResolvedBuildsNothing() {
        val state = transcript(
            AgentStreamPayload.ApprovalRequested("ap1", bash, reason = null),
            AgentStreamPayload.ApprovalResolved("ap1", AgentApprovalDecision.Deny),
        )
        assertNull(answerRequest(sessionID, pendingApprovals(state.rows), "ap1", ApprovalAnswer.Allow))
    }
}
