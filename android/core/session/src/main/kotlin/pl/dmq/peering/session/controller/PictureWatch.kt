package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.video.LanVideoLane

/**
 * Keeps the picture of one session going and says what state it is in. A local session has a [lane] to run; a relayed
 * one has none, because its picture rides the datagram lane and the control connection.
 */
internal class PictureWatch(private val clock: Clock, private val lane: LanVideoLane?) {
    private var job: Job? = null
    private var scope: CoroutineScope? = null
    private var seen = false
    private var automaticRetries = 0
    private var waitingSince = clock.monotonicSeconds()

    fun noteSeen() {
        seen = true
        automaticRetries = 0
    }

    /**
     * True once when a picture that never arrived has waited long enough to ask again by itself, up to [MAX_AUTOMATIC_RETRIES]
     * times. After that the state reads as stalled and the Retry button is the user's.
     */
    fun takeAutomaticRetry(): Boolean {
        if (seen || lane?.failure != null || automaticRetries >= MAX_AUTOMATIC_RETRIES) return false
        if (clock.monotonicSeconds() - waitingSince < STALL_SECONDS) return false
        automaticRetries += 1
        return true
    }

    fun start(scope: CoroutineScope) {
        this.scope = scope
        job?.cancel()
        job = lane?.let {
            it.reset()
            scope.launch { it.run() }
        }
    }

    /** Forgets the picture seen so far, so the area reads as waiting again, and reopens the lane from the first rung. */
    fun restart() {
        seen = false
        waitingSince = clock.monotonicSeconds()
        scope?.let(::start)
    }

    fun state(paused: Boolean, viaControlChannel: Boolean): PictureState {
        lane?.failure?.let { return if (paused) PictureState.Paused else PictureState.Failed(it) }
        return when {
            paused -> PictureState.Paused
            viaControlChannel -> PictureState.Fallback
            !seen && clock.monotonicSeconds() - waitingSince >= STALL_SECONDS -> PictureState.Stalled
            !seen -> PictureState.Connecting
            else -> PictureState.Live
        }
    }

    internal companion object {
        const val STALL_SECONDS = 6.0
        const val MAX_AUTOMATIC_RETRIES = 3
    }
}
