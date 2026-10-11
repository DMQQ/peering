package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentSessionState

class PromptQueueTest {
    @Test
    fun aPromptToAnIdleChatIsSentAtOnce() {
        val (queue, submission) = PromptQueue().submit("a", AgentSessionState.IDLE)
        assertEquals(PromptSubmission.SEND, submission)
        assertTrue(queue.prompts.isEmpty())
    }

    @Test
    fun aPromptWhileATurnRunsOrAwaitsApprovalIsQueued() {
        for (state in listOf(AgentSessionState.WORKING, AgentSessionState.AWAITING_APPROVAL)) {
            val (queue, submission) = PromptQueue().submit("a", state)
            assertEquals(PromptSubmission.QUEUED, submission)
            assertEquals(listOf("a"), queue.prompts)
        }
    }

    @Test
    fun aPromptToANewChatWithNoStateIsSentAtOnce() {
        assertEquals(PromptSubmission.SEND, PromptQueue().submit("a", null).second)
    }

    @Test
    fun waitingPromptsKeepTheOrderEvenOnceTheChatIsIdle() {
        val (first, _) = PromptQueue().submit("a", AgentSessionState.WORKING)
        val (queue, submission) = first.submit("b", AgentSessionState.IDLE)
        assertEquals(PromptSubmission.QUEUED, submission)
        assertEquals(listOf("a", "b"), queue.prompts)
    }

    @Test
    fun aFinishedTurnReleasesOneWaitingPromptAtATime() {
        val queued = PromptQueue(listOf("a", "b"))
        val (held, hold) = queued.release(AgentSessionState.WORKING)
        assertEquals(PromptRelease.Hold, hold)
        assertEquals(queued, held)

        val (afterFirst, first) = queued.release(AgentSessionState.IDLE)
        assertEquals(PromptRelease.Send("a"), first)
        assertEquals(listOf("b"), afterFirst.prompts)

        val (afterSecond, second) = afterFirst.release(AgentSessionState.IDLE)
        assertEquals(PromptRelease.Send("b"), second)
        assertEquals(PromptRelease.Hold, afterSecond.release(AgentSessionState.IDLE).second)
    }

    @Test
    fun aFailedOrEndedChatDiscardsWhatWaitedForIt() {
        for (state in listOf(AgentSessionState.FAILED, AgentSessionState.EXITED)) {
            val (queue, release) = PromptQueue(listOf("a")).release(state)
            assertEquals(PromptRelease.Dropped, release)
            assertTrue(queue.prompts.isEmpty())
        }
    }

    @Test
    fun anInterruptedTurnKeepsTheQueueAndTheNextPromptGoesOutWhenItStops() {
        val queued = PromptQueue(listOf("a"))
        val (queue, release) = queued.release(AgentSessionState.IDLE)
        assertEquals(PromptRelease.Send("a"), release)
        assertTrue(queue.prompts.isEmpty())
    }

    @Test
    fun removeDropsOnlyTheOffsetAskedFor() {
        val queue = PromptQueue(listOf("a", "b"))
        assertEquals(listOf("b"), queue.remove(0).prompts)
        assertEquals(queue, queue.remove(5))
        assertEquals(queue, queue.remove(-1))
    }
}
