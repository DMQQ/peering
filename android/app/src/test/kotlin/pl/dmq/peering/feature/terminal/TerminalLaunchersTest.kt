package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalsState
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64

class TerminalLaunchersTest {
    private val now = 10_000_000_000L
    private val hour = 3_600_000L
    private val day = 24 * hour

    private fun age(millisAgo: Long) = LaunchAge.between(now, now - millisAgo)

    @Test
    fun relativeTimesFollowTheNamedThresholds() {
        assertEquals(LaunchAge.JustNow, age(30_000))
        assertEquals(LaunchAge.Minutes(5), age(5 * 60_000))
        assertEquals(LaunchAge.Hours(4), age(4 * hour + 1))
        assertEquals(LaunchAge.Yesterday, age(day + hour))
        assertEquals(LaunchAge.Days(3), age(3 * day))
        assertEquals(LaunchAge.LastWeek, age(7 * day))
        assertEquals(LaunchAge.Weeks(3), age(21 * day))
        assertEquals(LaunchAge.LastMonth, age(35 * day))
        assertEquals(LaunchAge.Months(3), age(95 * day))
        assertEquals(LaunchAge.JustNow, LaunchAge.between(now, now + day))
    }

    @Test
    fun everyAgentIsOfferedUntilTheComputerHasAList() {
        val cards = TerminalListPresenter.launchers(TerminalsState(), emptyList(), now)
        assertEquals(TerminalAgent.all, cards.map { it.agent })
        assertNull(cards.first().lastUsed)
    }

    @Test
    fun nothingIsOfferedWhileTheListIsOnItsWay() {
        assertTrue(TerminalListPresenter.launchers(TerminalsState(agentListPending = true), emptyList(), now).isEmpty())
    }

    @Test
    fun onlyInstalledAgentsAreOfferedWithTheirLastUse() {
        val state = TerminalsState(installedAgents = setOf("codex", "aider"))
        val launches = listOf(AgentLaunch("codex", now - day - hour, "Mac"), AgentLaunch("codex", now - 9 * day, "Mac"))
        val cards = TerminalListPresenter.launchers(state, launches, now)
        assertEquals(listOf("codex", "aider"), cards.map { it.agent.id })
        assertEquals(LaunchAge.Yesterday, cards[0].lastUsed)
        assertNull(cards[1].lastUsed)
    }

    @Test
    fun historyRowsNameTheAgentAndTheComputer() {
        val launches = listOf(AgentLaunch("claude", now - 4 * hour, "Studio Mac"), AgentLaunch("zed", now, ""))
        val rows = TerminalListPresenter.historyRows(launches, now)
        assertEquals(HistoryRow("claude", "Claude Code", "Studio Mac", LaunchAge.Hours(4)), rows[0])
        assertEquals("zed", rows[1].title)
    }

    @Test
    fun historyKeepsNewestFirstAcrossReloadsAndClears() {
        val store = FakeKeyValueStore()
        val history = AgentLaunchHistory(store)
        history.record(AgentLaunch("codex", 1, "A\tB"))
        history.record(AgentLaunch("claude", 2, "A"))
        assertEquals(listOf("claude", "codex"), AgentLaunchHistory(store).all.value.map { it.agentID })
        assertEquals(1L, history.lastUsedMillis("codex"))
        assertNull(history.lastUsedMillis("aider"))
        history.clear()
        assertTrue(AgentLaunchHistory(store).all.value.isEmpty())
    }

    @Test
    fun historyIsCapped() {
        val history = AgentLaunchHistory(FakeKeyValueStore())
        repeat(60) { history.record(AgentLaunch("claude", it.toLong(), "")) }
        assertEquals(50, history.all.value.size)
        assertEquals(59L, history.all.value.first().atMillis)
    }

    private class Flow {
        val sent = mutableListOf<TerminalRequest>()
        val sessions = TerminalSessions(send = { sent += it })
        val history = AgentLaunchHistory(FakeKeyValueStore())
        val presenter = TerminalListPresenter(sessions, history, computerName = { "Studio Mac" }, nowMillis = { 42L })

        fun created(id: String) {
            sessions.onEvent(TerminalEvent.Created(TerminalSessionInfo(id, id, true, null, null)))
            presenter.onState(sessions.state.value)
        }
    }

    @Test
    fun startingAnAgentOpensAShellThenTypesTheCommandAndReturn() {
        val flow = Flow()
        flow.presenter.start(TerminalAgent.byId("codex")!!)
        assertEquals(listOf<TerminalRequest>(TerminalRequest.Create), flow.sent)
        flow.created("shell-1")
        assertEquals(TerminalRequest.Input("shell-1", "codex\r".toByteArray().toBase64()), flow.sent.last())
        assertEquals(listOf(AgentLaunch("codex", 42L, "Studio Mac")), flow.history.all.value)
        assertTrue(flow.presenter.inShell.value)
    }

    @Test
    fun aPlainShellGetsNoCommand() {
        val flow = Flow()
        flow.presenter.create()
        flow.created("shell-1")
        assertEquals(listOf<TerminalRequest>(TerminalRequest.Create), flow.sent)
    }

    @Test
    fun aFailedStartDoesNotTypeIntoTheNextShell() {
        val flow = Flow()
        flow.presenter.start(TerminalAgent.byId("claude")!!)
        flow.sessions.onEvent(TerminalEvent.Failed(null, "no shell"))
        flow.presenter.onState(flow.sessions.state.value)
        flow.presenter.create()
        flow.created("shell-2")
        assertEquals(2, flow.sent.size)
    }
}
