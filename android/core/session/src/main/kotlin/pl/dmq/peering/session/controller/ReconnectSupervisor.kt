package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.wire.ReconnectLadder
import kotlin.time.Duration

/**
 * Paces the attempts to reopen a dropped session. Each wait follows the the reconnect ladder; a network change or a
 * picture that arrives starts the ladder again, and a network change also ends a wait that is already running.
 */
internal class ReconnectSupervisor {
    private val ladder = ReconnectLadder()
    private val networkChanges = Channel<Unit>(Channel.CONFLATED)

    /** Attempts made since the ladder last restarted. */
    var attempt: Int = 0
        private set

    /** The wait before the next attempt, or null once every step is used. */
    fun nextStep(): Duration? = ladder.next()?.also { attempt += 1 }

    /** Waits out [step], or returns early when the network changes. */
    suspend fun waitFor(step: Duration) {
        networkChanges.tryReceive()
        withTimeoutOrNull(step) { networkChanges.receive() }
    }

    fun pictureArrived() {
        ladder.reset()
        attempt = 0
    }

    fun networkChanged() {
        pictureArrived()
        networkChanges.trySend(Unit)
    }
}
