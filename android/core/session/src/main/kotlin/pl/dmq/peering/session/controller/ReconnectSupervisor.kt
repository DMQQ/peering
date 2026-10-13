package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.wire.ReconnectLadder
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Paces the attempts to reopen a dropped session on the iPhone's ladder, long enough to outlast the Mac app restarting.
 * A network change, a link that reaches Ready or a picture that arrives starts the ladder and its window again, and a network change also ends a
 * wait that is already running.
 */
internal class ReconnectSupervisor(private val clock: Clock) {
    private val ladder = ReconnectLadder(DELAYS)
    private val networkChanges = Channel<Unit>(Channel.CONFLATED)
    private var windowStartedAt: Double? = null

    /** Attempts made since the ladder last restarted. */
    var attempt: Int = 0
        private set

    /** The wait before the next attempt, or null once every step is used or the window has closed. */
    fun nextStep(): Duration? {
        val now = clock.monotonicSeconds()
        val started = windowStartedAt ?: now.also { windowStartedAt = it }
        if (now - started >= WINDOW.inWholeSeconds) return null
        return ladder.next()?.also { attempt += 1 }
    }

    /** Waits out [step], or returns early when the network changes. */
    suspend fun waitFor(step: Duration) {
        networkChanges.tryReceive()
        withTimeoutOrNull(step) { networkChanges.receive() }
    }

    fun pictureArrived() = restartLadder()

    /** A link that reached Ready proves the path works, whether or not video is flowing. */
    fun linkReady() = restartLadder()

    fun networkChanged() {
        restartLadder()
        networkChanges.trySend(Unit)
    }

    private fun restartLadder() {
        ladder.reset()
        windowStartedAt = null
        attempt = 0
    }

    companion object {
        val DELAYS: List<Duration> = listOf(250.milliseconds, 1.seconds, 3.seconds, 5.seconds, 8.seconds, 10.seconds)
        val WINDOW: Duration = 30.seconds
    }
}
