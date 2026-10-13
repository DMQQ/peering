package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.PromptQueue
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class TranscriptPresenterTest {
    private fun session(
        rows: List<TranscriptRow> = emptyList(),
        state: AgentSessionState = AgentSessionState.IDLE,
        historyLoaded: Boolean = true,
        prompts: List<String> = emptyList(),
    ) = AgentChatSession(
        info = AgentSessionInfo("S1", "claude", "t", "/d", state, lastIndex = 0, createdAt = 0.0),
        transcript = TranscriptState(rows = rows, sessionState = state),
        prompts = PromptQueue(prompts),
        historyLoaded = historyLoaded,
    )

    private fun presenter(initial: AgentChatState): Pair<MutableStateFlow<AgentChatState>, TranscriptPresenter> {
        val chats = MutableStateFlow(initial)
        val scope = CoroutineScope(UnconfinedTestDispatcher())
        return chats to TranscriptPresenter(chats, scope)
    }

    private fun userRow(id: Long, text: String) = TranscriptRow.User(id, text)

    @Test
    fun selectedChatRowsAndQueuedPromptsAreShown() = runTest {
        val state = AgentChatState(
            sessions = listOf(session(rows = listOf(userRow(1, "hi")), prompts = listOf("next"))),
            selectedSessionID = "S1",
        )
        val (_, presenter) = presenter(state)
        val ui = presenter.ui.value
        assertEquals(listOf(userRow(1, "hi")), ui.rows)
        assertEquals(listOf("next"), ui.queuedPrompts)
    }

    @Test
    fun noSelectionShowsNoRows() = runTest {
        val (_, presenter) = presenter(AgentChatState(sessions = listOf(session(rows = listOf(userRow(1, "hi"))))))
        assertTrue(presenter.ui.value.rows.isEmpty())
    }

    @Test
    fun workingAndAwaitingApprovalCountAsWorking() = runTest {
        val working = AgentChatState(listOf(session(state = AgentSessionState.WORKING)), "S1")
        val (_, presenter) = presenter(working)
        assertTrue(presenter.ui.value.working)
        val waiting = AgentChatState(listOf(session(state = AgentSessionState.AWAITING_APPROVAL)), "S1")
        val (_, other) = presenter(waiting)
        assertTrue(other.ui.value.working)
    }

    @Test
    fun historyIsLoadingUntilTheChatHasBeenReplayed() = runTest {
        val (_, presenter) = presenter(AgentChatState(listOf(session(historyLoaded = false)), "S1"))
        assertTrue(presenter.ui.value.loadingHistory)
    }

    @Test
    fun toggleOpensAndClosesAToolCard() = runTest {
        val (_, presenter) = presenter(AgentChatState(listOf(session()), "S1"))
        presenter.toggleTool(7)
        assertEquals(setOf(7L), presenter.ui.value.expandedToolIDs)
        presenter.toggleTool(7)
        assertTrue(presenter.ui.value.expandedToolIDs.isEmpty())
    }

    @Test
    fun newRowsWhileScrolledAwayAreCountedUntilTheListIsBackAtTheBottom() = runTest {
        val (chats, presenter) = presenter(AgentChatState(listOf(session(rows = listOf(userRow(1, "a")))), "S1"))
        presenter.onUserScrolled(atBottom = false)
        assertFalse(presenter.ui.value.following)
        chats.value = AgentChatState(listOf(session(rows = listOf(userRow(1, "a"), userRow(2, "b"), userRow(3, "c")))), "S1")
        assertEquals(2, presenter.ui.value.unseenRows)
        presenter.onUserScrolled(atBottom = true)
        assertTrue(presenter.ui.value.following)
        assertEquals(0, presenter.ui.value.unseenRows)
    }

    @Test
    fun sendingAPromptFollowsAgain() = runTest {
        val (_, presenter) = presenter(AgentChatState(listOf(session(rows = listOf(userRow(1, "a")))), "S1"))
        presenter.onUserScrolled(atBottom = false)
        presenter.followLatest()
        assertTrue(presenter.ui.value.following)
    }
}
