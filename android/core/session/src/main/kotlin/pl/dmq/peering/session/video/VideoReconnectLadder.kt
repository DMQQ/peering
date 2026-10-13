package pl.dmq.peering.session.video

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The waits before each new attempt at the local picture connection. The first is short because a socket that closed
 * under a network change usually opens on the next try. It restarts when a picture arrives, not when a socket opens:
 * a socket that connects and says nothing is the failure this ladder exists for.
 */
internal class VideoReconnectLadder {
    private var attempts = 0

    fun next(): Duration? = DELAYS.getOrNull(attempts)?.also { attempts += 1 }

    fun reset() {
        attempts = 0
    }

    companion object {
        val DELAYS = listOf(500.milliseconds, 1.seconds, 2.seconds, 5.seconds, 5.seconds)
    }
}
