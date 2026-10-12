package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentUsage

class ChatPresenterTest {
    private val usage = AgentUsage(
        contextUsedTokens = 70_000, contextWindowTokens = 200_000, inputTokens = 1, cachedTokens = 0, outputTokens = 2, limits = emptyList(),
    )

    private fun session(
        state: AgentSessionState = AgentSessionState.IDLE,
        rows: List<TranscriptRow> = listOf(TranscriptRow.User(1, "hi")),
        loaded: Boolean = true,
        withUsage: Boolean = true,
    ) = AgentChatSession(
        info = AgentSessionInfo(
            id = "A", agentID = "codex", title = "Fix", directory = "/work", state = state, lastIndex = 0,
            usage = usage.takeIf { withUsage }, createdAt = 0.0,
        ),
        transcript = TranscriptState(rows = rows),
        historyLoaded = loaded,
    )

    private fun presenter(port: FakeAgentsPort) = ChatPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    private fun port(session: AgentChatSession, capabilities: AgentCapabilities = AgentCapabilities(chat = true, usage = true, pause = true)) =
        FakeAgentsPort(AgentChatState(sessions = listOf(session), selectedSessionID = "A"), capabilities)

    @Test
    fun theHeaderNamesTheChatAndItsAgent() {
        val ui = presenter(port(session())).ui.value
        assertEquals("Fix", ui.title)
        assertEquals("/work", ui.directory)
        assertEquals("Codex", ui.agentName)
    }

    @Test
    fun usageShowsOnlyWhenTheComputerDeclaredIt() {
        assertNotNull(presenter(port(session())).ui.value.chip)
        val undeclared = presenter(port(session(), AgentCapabilities(chat = true))).ui.value
        assertNull(undeclared.chip)
        assertFalse(undeclared.usageSupported)
    }

    @Test
    fun noChipWhenTheCliReportedNothing() {
        assertNull(presenter(port(session(withUsage = false))).ui.value.chip)
    }

    @Test
    fun pauseIsOfferedOnlyToAQuietChatWithAConversationOnAHostThatDeclaredIt() {
        assertTrue(presenter(port(session())).ui.value.canPause)
        assertFalse(presenter(port(session(state = AgentSessionState.WORKING))).ui.value.canPause)
        assertFalse(presenter(port(session(rows = emptyList()))).ui.value.canPause)
        assertFalse(presenter(port(session(), AgentCapabilities(chat = true))).ui.value.canPause)
    }

    @Test
    fun pauseSendsOnceItIsAllowedAndNothingOtherwise() {
        val allowed = port(session())
        assertTrue(presenter(allowed).pause())
        assertEquals(listOf("pause:A"), allowed.calls)

        val refused = port(session(state = AgentSessionState.WORKING))
        assertFalse(presenter(refused).pause())
        assertEquals(emptyList<String>(), refused.calls)
    }

    @Test
    fun theEmptyStateShowsOnceTheHistoryLoadedAndNothingWasSaid() {
        assertTrue(presenter(port(session(rows = emptyList()))).ui.value.showEmptyState)
        assertFalse(presenter(port(session(rows = emptyList(), loaded = false))).ui.value.showEmptyState)
        assertFalse(presenter(port(session())).ui.value.showEmptyState)
    }

    @Test
    fun aSuggestionIsSentAsAPromptAndAClosedChatIsClosed() {
        val port = port(session(rows = emptyList()))
        val presenter = presenter(port)
        presenter.suggest("What does this project do?")
        presenter.close()
        assertEquals(listOf("prompt:A:What does this project do?", "close:A"), port.calls)
    }

    @Test
    fun anEndedChatIsMarkedSo() {
        assertTrue(presenter(port(session(state = AgentSessionState.EXITED))).ui.value.ended)
        assertFalse(presenter(port(session())).ui.value.ended)
    }
}
