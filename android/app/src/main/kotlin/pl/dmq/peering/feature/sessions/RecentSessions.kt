package pl.dmq.peering.feature.sessions

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.history.SessionRecord

/** The sessions the Sessions tab lists, newest first. The wiring keeps them current and stored. */
interface SessionRecords {
    val records: StateFlow<List<SessionRecord>>
}

/** What the summary line over the list says about the sessions it lists. */
data class RecentSummary(val sessionCount: Int, val connectedSeconds: Long, val relaySeconds: Long) {
    companion object {
        fun of(records: List<SessionRecord>, nowMillis: Long): RecentSummary = RecentSummary(
            sessionCount = records.size,
            connectedSeconds = records.sumOf { it.durationSeconds(nowMillis) },
            relaySeconds = records.filter { it.path == SessionRecord.Path.RELAY }.sumOf { it.durationSeconds(nowMillis) },
        )
    }
}

/** How long the session ran, up to [nowMillis] while it is still open. */
fun SessionRecord.durationSeconds(nowMillis: Long): Long =
    (((endedAt ?: nowMillis) - startedAt) / MILLIS_PER_SECOND).coerceAtLeast(0)

/** "45s" under a minute, else "12m 4s", as the phone words a session's length. */
fun durationLabel(seconds: Long): String =
    if (seconds < SECONDS_PER_MINUTE) "${seconds}s" else "${seconds / SECONDS_PER_MINUTE}m ${seconds % SECONDS_PER_MINUTE}s"

private const val MILLIS_PER_SECOND = 1_000L
private const val SECONDS_PER_MINUTE = 60L
