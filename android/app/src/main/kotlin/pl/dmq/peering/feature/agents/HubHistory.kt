package pl.dmq.peering.feature.agents

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** What tapping a history row does: bring a paused chat back, or continue a conversation found on the computer. */
sealed interface HistoryAction {
    data class OpenPaused(val sessionID: String) : HistoryAction

    data class Resume(val resumableID: String, val openElsewhere: Boolean) : HistoryAction
}

/** One row of the history card. [dateUnix] is seconds since the Unix epoch. */
data class HistoryEntry(
    val id: String,
    val agentID: String,
    val title: String,
    val detail: String,
    val dateUnix: Long,
    val action: HistoryAction,
)

/** The day a group of rows is filed under. */
sealed interface HistoryDay {
    data object Today : HistoryDay

    data object Yesterday : HistoryDay

    data class On(val date: LocalDate) : HistoryDay
}

data class HistoryGroup(val day: HistoryDay, val entries: List<HistoryEntry>)

object HubHistory {
    /** Paused chats and conversations nobody has open on the computer, newest first. */
    fun entries(ui: HubUi): List<HistoryEntry> {
        val paused = ui.history.map {
            HistoryEntry(
                id = it.id,
                agentID = it.agentID,
                title = it.title,
                detail = folderName(it.directory),
                dateUnix = it.lastActivityUnix,
                action = HistoryAction.OpenPaused(it.id),
            )
        }
        return (paused + ui.resumable.filterNot { it.openElsewhere }.map(::resumableEntry)).sortedByDescending { it.dateUnix }
    }

    /** Conversations written to a moment ago: a terminal on the computer probably has them open. */
    fun activeOnComputer(ui: HubUi): List<HistoryEntry> =
        ui.resumable.filter { it.openElsewhere }.map(::resumableEntry).sortedByDescending { it.dateUnix }

    /** Rows in the order given, filed under Today, Yesterday or their date; a day appears once, where it first occurs. */
    fun group(entries: List<HistoryEntry>, nowUnix: Long, zone: ZoneId): List<HistoryGroup> {
        val today = Instant.ofEpochSecond(nowUnix).atZone(zone).toLocalDate()
        val order = mutableListOf<HistoryDay>()
        val buckets = mutableMapOf<HistoryDay, MutableList<HistoryEntry>>()
        for (entry in entries) {
            val date = Instant.ofEpochSecond(entry.dateUnix).atZone(zone).toLocalDate()
            val day = when (date) {
                today -> HistoryDay.Today
                today.minusDays(1) -> HistoryDay.Yesterday
                else -> HistoryDay.On(date)
            }
            if (day !in buckets) order += day
            buckets.getOrPut(day) { mutableListOf() } += entry
        }
        return order.map { HistoryGroup(it, buckets.getValue(it)) }
    }

    private fun resumableEntry(card: ResumableCard) = HistoryEntry(
        id = card.id,
        agentID = card.agentID,
        title = card.title,
        detail = folderName(card.directory),
        dateUnix = card.modifiedAtUnix,
        action = HistoryAction.Resume(card.id, card.openElsewhere),
    )

    private fun folderName(directory: String): String = directory.trimEnd('/').substringAfterLast('/').ifEmpty { directory }
}
