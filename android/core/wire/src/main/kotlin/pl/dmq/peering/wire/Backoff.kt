package pl.dmq.peering.wire

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Delays between attempts to reopen a direct video socket. The first is deliberately short: a socket that closed
 * because the network moved under it usually succeeds on the next try. Call [reset] when a picture actually arrives,
 * not when a socket opens, since a socket that connects and then says nothing is the failure this ladder exists for.
 */
class ReconnectLadder {
    private var attempts = 0

    /** The delay before the next attempt, or null once every step has been used. */
    fun next(): Duration? {
        if (attempts >= DELAYS.size) return null
        return DELAYS[attempts++]
    }

    fun reset() {
        attempts = 0
    }

    private companion object {
        val DELAYS: List<Duration> = listOf(500.milliseconds, 1.seconds, 2.seconds, 5.seconds, 5.seconds)
    }
}
