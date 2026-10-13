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
    private var automaticNudges = 0
    private var waitingSince = clock.monotonicSeconds()

    fun noteSeen() {
        seen = true
        automaticNudges = 0
    }

    /**
     * True when a picture that never arrived has waited another [STALL_SECONDS], up to [MAX_AUTOMATIC_NUDGES] times: the caller asks
     * the computer for a fresh keyframe, which fixes a stream that is open but silent. The lane is left alone, since it runs its own
     * retries and a refused key must not be tried again. The state still reads as stalled meanwhile, so Retry stays in reach.
     */
    fun takeAutomaticNudge(): Boolean {
        if (seen || automaticNudges >= MAX_AUTOMATIC_NUDGES) return false
        if (clock.monotonicSeconds() - waitingSince < STALL_SECONDS * (automaticNudges + 1)) return false
        automaticNudges += 1
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
        automaticNudges = 0
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

    private companion object {
        const val STALL_SECONDS = 6.0
        const val MAX_AUTOMATIC_NUDGES = 3
    }
}
