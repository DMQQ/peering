package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ApprovalStatus
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState
import pl.dmq.peering.wire.AgentToolCall

class AgentsHubPresenterTest {
    private fun info(
        id: String,
        state: AgentSessionState = AgentSessionState.IDLE,
        directory: String = "/Users/me/app",
    ) = AgentSessionInfo(
        id = id, agentID = "claude", title = "Fix $id", directory = directory,
        state = state, lastIndex = 0, createdAt = 0.0,
    )

    private class Harness(
        port: FakeAgentsPort,
        declared: List<String> = listOf("claude", "codex"),
        supported: Boolean = true,
        clock: FakeClock = FakeClock(),
    ) {
        val folderRequests = mutableListOf<String?>()
        val folders: FolderPicker
        val presenter: AgentsHubPresenter

        init {
            val scope = CoroutineScope(UnconfinedTestDispatcher())
            folders = FolderPicker({ folderRequests += it }, scope)
            presenter = AgentsHubPresenter(port, declared, supported, folders, clock, scope)
        }
    }

    private fun approvalRow(id: Long, status: ApprovalStatus) = TranscriptRow.Approval(
        id = id,
        approvalID = "A$id",
        call = AgentToolCall(id = "c$id", name = "Bash", title = "Bash"),
        reason = null,
        status = status,
    )

    @Test
    fun cardCarriesTitleDirectoryAndStateOfEachChat() = runTest {
        val port = FakeAgentsPort(AgentChatState(sessions = listOf(AgentChatSession(info("S1", AgentSessionState.WORKING)))))
        val ui = Harness(port).presenter.ui.value
        val card = ui.sessions.single()
        assertEquals("Fix S1", card.title)
        assertEquals("/Users/me/app", card.directory)
        assertEquals(SessionCardState.WORKING, card.state)
        assertEquals(0, card.pendingApprovals)
    }

    @Test
    fun openApprovalCountsAsAPendingBadgeAndNeedsYou() = runTest {
        val transcript = TranscriptState(rows = listOf(approvalRow(1, ApprovalStatus.Pending), approvalRow(2, ApprovalStatus.Pending)))
        val session = AgentChatSession(info("S1", AgentSessionState.WORKING), transcript = transcript)
        val ui = Harness(FakeAgentsPort(AgentChatState(sessions = listOf(session)))).presenter.ui.value
        assertEquals(2, ui.sessions.single().pendingApprovals)
        assertEquals(SessionCardState.NEEDS_YOU, ui.sessions.single().state)
    }

    @Test
    fun answeredApprovalIsNoLongerBadged() = runTest {
        val transcript = TranscriptState(rows = listOf(approvalRow(1, ApprovalStatus.Cancelled)))
        val session = AgentChatSession(info("S1"), transcript = transcript)
        val ui = Harness(FakeAgentsPort(AgentChatState(sessions = listOf(session)))).presenter.ui.value
        assertEquals(0, ui.sessions.single().pendingApprovals)
        assertEquals(SessionCardState.IDLE, ui.sessions.single().state)
    }

    @Test
    fun endedAndFailedChatsGetTheirOwnStates() = runTest {
        val sessions = listOf(
            AgentChatSession(info("E", AgentSessionState.EXITED)),
            AgentChatSession(info("F", AgentSessionState.FAILED)),
        )
        val cards = Harness(FakeAgentsPort(AgentChatState(sessions = sessions))).presenter.ui.value.sessions
        assertEquals(mapOf("E" to SessionCardState.ENDED, "F" to SessionCardState.FAILED), cards.associate { it.id to it.state })
    }

    @Test
    fun cardsAreOrderedByLastActivityNewestFirst() = runTest {
        val clock = FakeClock(unix = 1_000_000_000L)
        val port = FakeAgentsPort(AgentChatState(sessions = listOf(AgentChatSession(info("OLD")), AgentChatSession(info("NEW")))))
        val harness = Harness(port, clock = clock)
        harness.presenter.ui.value
        clock.unix = 1_000_000_500L
        port.chatState.value = port.chatState.value.replacingSession(
            AgentChatSession(info("NEW").copy(lastIndex = 5)),
        )
        assertEquals(listOf("NEW", "OLD"), harness.presenter.ui.value.sessions.map { it.id })
    }

    @Test
    fun selectingAndClosingGoThroughThePort() = runTest {
        val port = FakeAgentsPort()
        val presenter = Harness(port).presenter
        presenter.openSession("S1")
        presenter.closeSession("S1")
        assertEquals(listOf("select:S1", "close:S1"), port.calls)
    }

    @Test
    fun newChatStartsWithAgentChoiceAndFolderListingForThatAgent() = runTest {
        val port = FakeAgentsPort()
        val harness = Harness(port)
        harness.presenter.beginNewChat()
        assertEquals(NewChatStep.ChoosingAgent, harness.presenter.ui.value.newChat)
        harness.presenter.chooseAgent("codex")
        assertEquals(NewChatStep.ChoosingFolder("codex"), harness.presenter.ui.value.newChat)
        assertEquals(listOf<String?>(null), harness.folderRequests)
    }

    @Test
    fun startingWaitsForAFolderListingThenSendsTheChosenPath() = runTest {
        val port = FakeAgentsPort()
        val harness = Harness(port)
        harness.presenter.beginNewChat()
        harness.presenter.chooseAgent("claude")
        harness.presenter.startInChosenFolder()
        assertTrue(port.calls.isEmpty())
        harness.folders.onEvent(AgentEvent.Directory("/Users/me", emptyList(), truncated = false))
        harness.presenter.startInChosenFolder()
        assertEquals(listOf("start:claude:/Users/me"), port.calls)
        assertEquals(NewChatStep.Closed, harness.presenter.ui.value.newChat)
    }

    @Test
    fun backFromFolderReturnsToTheAgentChoice() = runTest {
        val harness = Harness(FakeAgentsPort())
        harness.presenter.beginNewChat()
        harness.presenter.chooseAgent("claude")
        harness.presenter.backToAgents()
        assertEquals(NewChatStep.ChoosingAgent, harness.presenter.ui.value.newChat)
    }

    @Test
    fun unknownAgentIsIgnored() = runTest {
        val harness = Harness(FakeAgentsPort())
        harness.presenter.beginNewChat()
        harness.presenter.chooseAgent("gemini")
        assertEquals(NewChatStep.ChoosingAgent, harness.presenter.ui.value.newChat)
        assertTrue(harness.folderRequests.isEmpty())
    }

    @Test
    fun withoutChatSupportNoAgentsAreOfferedAndNoFlowOpens() = runTest {
        val harness = Harness(FakeAgentsPort(), supported = false)
        harness.presenter.beginNewChat()
        assertTrue(harness.presenter.ui.value.agents.isEmpty())
        assertEquals(NewChatStep.Closed, harness.presenter.ui.value.newChat)
    }

    @Test
    fun agentsListFollowsTheHostsDeclaration() = runTest {
        val harness = Harness(FakeAgentsPort(), declared = listOf("opencode"))
        assertEquals(listOf(AgentOption("opencode", "OpenCode")), harness.presenter.ui.value.agents)
    }
}
