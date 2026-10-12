package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.ByteTally
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.history.SessionTrail
import pl.dmq.peering.wire.ServerHello

/** What one session leaves behind: its entry in the history, the bytes it moved and the notes of what it did. */
internal class SessionRecorder(private val ports: SessionPorts, private val history: SessionHistory) {
    val tally = ByteTally()
    private val trail = SessionTrail(beganAtMillis = nowMillis())
    private var historyId: Long? = null

    fun note(message: String) {
        ports.log.log(message)
        trail.add(message, nowMillis())
    }

    /** Opens the history entry on the first ready link; a reconnect continues the same entry. */
    fun begin(hello: ServerHello, path: SessionRecord.Path) {
        if (historyId == null) historyId = history.begin(hello.serverID, hello.hostName, path, nowMillis())
    }

    fun end(reason: SessionRecord.EndReason) {
        val id = historyId ?: return
        note("session ended: $reason")
        history.end(id, nowMillis(), reason, tally.received, tally.sent, trail.entries)
        historyId = null
    }

    private fun nowMillis(): Long = ports.clock.unixSeconds() * MILLIS_PER_SECOND

    private companion object {
        const val MILLIS_PER_SECOND = 1000L
    }
}
