package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentCapabilities
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.AgentPause
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentResumableSession
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class HubHistoryAndImportTest {
    private fun info(id: String, state: AgentSessionState = AgentSessionState.IDLE) = AgentSessionInfo(
        id = id, agentID = "claude", title = "Chat $id", directory = "/work",
        state = state, lastIndex = 0, createdAt = 0.0,
    )

    private fun talked(id: String, paused: Boolean = false, state: AgentSessionState = AgentSessionState.IDLE): AgentChatSession {
        val rows = buildList<TranscriptRow> {
            add(TranscriptRow.User(1, "hi"))
            if (paused) add(TranscriptRow.Notice(2, AgentPause.NOTICE))
        }
        return AgentChatSession(info(id, state), transcript = TranscriptState(rows = rows))
    }

    private fun hub(port: FakeAgentsPort): AgentsHubPresenter {
        val scope = CoroutineScope(UnconfinedTestDispatcher())
        val folders = FolderPicker({}, scope)
        return AgentsHubPresenter(port, listOf("claude", "codex"), true, folders, FolderRecents(InMemoryFolderRecentsStore(), "mac"), FakeClock(), scope)
    }

    private fun resumable(mayBeOpen: Boolean = false, agentID: String = "claude") =
        AgentResumableSession(agentID, "cli1", "/work", "Fix tests", 100.0, mayBeOpen)

    @Test
    fun pausedChatsLeaveTheChatListForHistory() {
        val port = FakeAgentsPort(AgentChatState(sessions = listOf(talked("A"), talked("B", paused = true))))
        val ui = hub(port).ui.value
        assertEquals(listOf("A"), ui.sessions.map { it.id })
        assertEquals(listOf("B"), ui.history.map { it.id })
        assertEquals(SessionCardState.PAUSED, ui.history.single().state)
    }

    @Test
    fun endingAQuietConversationPausesItWhenTheHostCanAndClosesOtherwise() {
        val port = FakeAgentsPort(AgentChatState(sessions = listOf(talked("A"))))
        hub(port).endSession("A")
        assertEquals(listOf("pause:A"), port.calls)

        val noPause = FakeAgentsPort(AgentChatState(sessions = listOf(talked("A"))), AgentCapabilities(chat = true))
        hub(noPause).endSession("A")
        assertEquals(listOf("close:A"), noPause.calls)
    }

    @Test
    fun endingAWorkingChatClosesIt() {
        val port = FakeAgentsPort(AgentChatState(sessions = listOf(talked("A", state = AgentSessionState.WORKING))))
        hub(port).endSession("A")
        assertEquals(listOf("close:A"), port.calls)
    }

    @Test
    fun refreshListsTheComputersConversationsOnlyWithImportSupport() {
        val port = FakeAgentsPort()
        hub(port).refresh()
        assertEquals(listOf("list", "listResumable"), port.calls)

        val without = FakeAgentsPort(capabilities = AgentCapabilities(chat = true))
        hub(without).refresh()
        assertEquals(listOf("list"), without.calls)
    }

    @Test
    fun resumableConversationsAreOfferedForDeclaredAgentsNewestFirstAndContinuedUnlessOpenElsewhere() {
        val port = FakeAgentsPort()
        port.resumableList.value = listOf(
            resumable(),
            resumable(agentID = "gemini"),
            AgentResumableSession("claude", "cli2", "/other", "Busy", 200.0, mayBeOpenElsewhere = true),
        )
        val presenter = hub(port)
        assertEquals(listOf("Busy", "Fix tests"), presenter.ui.value.resumable.map { it.title })
        assertTrue(presenter.ui.value.resumable.first().openElsewhere)

        assertFalse(presenter.resume("claude:cli2"))
        assertTrue(presenter.resume("claude:cli1"))
        assertEquals(listOf("resume:claude:cli1"), port.calls)
    }

    @Test
    fun aConversationOpenElsewhereIsContinuedWhenTheUserConfirmsAnyway() {
        val port = FakeAgentsPort()
        port.resumableList.value = listOf(AgentResumableSession("claude", "cli2", "/other", "Busy", 200.0, mayBeOpenElsewhere = true))
        val presenter = hub(port)
        assertTrue(presenter.resume("claude:cli2", anyway = true))
        assertEquals(listOf("resume:claude:cli2"), port.calls)
    }

    @Test
    fun noImportSectionWithoutHostSupport() {
        val port = FakeAgentsPort(capabilities = AgentCapabilities(chat = true))
        port.resumableList.value = listOf(resumable())
        val presenter = hub(port)
        assertTrue(presenter.ui.value.resumable.isEmpty())
        assertFalse(presenter.ui.value.canImport)
        assertFalse(presenter.resume("claude:cli1"))
    }
}
