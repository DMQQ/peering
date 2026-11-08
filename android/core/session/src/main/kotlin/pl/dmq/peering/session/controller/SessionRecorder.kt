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
    private var timingOrigin = ports.clock.monotonicSeconds()

    /** Starts the clock the [mark]s are read against, so each reads as time since the person asked to connect. */
    fun restartTiming() {
        timingOrigin = ports.clock.monotonicSeconds()
    }

    /** A note that says how long after [restartTiming] it happened, to find which step of a connect is the slow one. It also goes to [SessionPorts.timing], so a release build can be read over adb: marks name steps, never addresses. */
    fun mark(event: String) {
        val elapsedMillis = ((ports.clock.monotonicSeconds() - timingOrigin) * MILLIS_PER_SECOND).toLong()
        val line = "+$elapsedMillis ms $event"
        note(line)
        ports.timing.log(line)
    }

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
