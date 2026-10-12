package pl.dmq.peering.feature.agents

import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Test

class HubHistoryTest {
    private val day = 86_400L
    private val now = 1_000_000_000L + 12 * 3_600L

    private fun entry(id: String, ageSeconds: Long) = HistoryEntry(
        id = id, agentID = "claude", title = id, detail = "app", dateUnix = now - ageSeconds,
        action = HistoryAction.OpenPaused(id),
    )

    private fun hub(history: List<SessionCard>, resumable: List<ResumableCard>) = HubUi(
        sessions = emptyList(), history = history, resumable = resumable, canImport = true, selectedSessionID = null,
        agents = emptyList(), agentUsage = emptyList(), selectedAgentID = null, newChat = NewChatStep.Closed,
        failure = null, recentFolders = emptyList(),
    )

    private fun resumable(id: String, modified: Long, elsewhere: Boolean) = ResumableCard(
        id = id, agentID = "claude", agentName = "Claude Code", title = id, directory = "/Users/me/app/",
        modifiedAtUnix = modified, openElsewhere = elsewhere,
    )

    @Test
    fun rowsAreFiledUnderTodayYesterdayAndTheirDate() {
        val groups = HubHistory.group(
            listOf(entry("a", 60), entry("b", day), entry("c", 5 * day), entry("d", 5 * day + 60)),
            now,
            ZoneOffset.UTC,
        )
        assertEquals(
            listOf(HistoryDay.Today, HistoryDay.Yesterday, HistoryDay.On(LocalDate.of(2001, 9, 4))),
            groups.map { it.day },
        )
        assertEquals(listOf("c", "d"), groups.last().entries.map { it.id })
    }

    @Test
    fun conversationsOpenOnTheComputerLeaveHistoryAndFormTheirOwnList() {
        val ui = hub(emptyList(), listOf(resumable("old", now - day, elsewhere = false), resumable("live", now - 10, elsewhere = true)))
        assertEquals(listOf("old"), HubHistory.entries(ui).map { it.id })
        assertEquals(listOf("live"), HubHistory.activeOnComputer(ui).map { it.id })
    }

    @Test
    fun historyIsNewestFirstAndNamesTheFolder() {
        val paused = SessionCard(
            id = "p", agentID = "claude", title = "Paused", directory = "/Users/me/api", state = SessionCardState.PAUSED,
            lastActivityUnix = now - 5 * day, pendingApprovals = 0, agentName = "Claude Code",
        )
        val ui = hub(listOf(paused), listOf(resumable("r", now - day, elsewhere = false)))
        val entries = HubHistory.entries(ui)
        assertEquals(listOf("r", "p"), entries.map { it.id })
        assertEquals(listOf("app", "api"), entries.map { it.detail })
    }
}
