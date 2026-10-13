package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.video.LanVideoLane

/** What a picture that has not arrived calls for next. */
internal enum class PictureEscalation { NONE, KEYFRAME, REOPEN, RECONNECT }

/**
 * Keeps the picture of one session going and says what state it is in. A local session has a [lane] to run; a relayed
 * one has none, because its picture rides the datagram lane and the control connection.
 */
internal class PictureWatch(private val clock: Clock, private val lane: LanVideoLane?) {
    private var job: Job? = null
    private var scope: CoroutineScope? = null
    private var seen = false
    private var automaticNudges = 0
    private var automaticRestarts = 0
    private var waitingSince = clock.monotonicSeconds()

    fun noteSeen() {
        seen = true
        automaticNudges = 0
        automaticRestarts = 0
    }

    /**
     * What to do about a picture that never arrived, asked once per tick. Up to [MAX_AUTOMATIC_NUDGES] times, each [STALL_SECONDS],
     * the computer is asked for a fresh keyframe, which fixes a stream that is open but silent. After [GIVE_UP_SECONDS] the picture
     * is reopened once, and if that waits as long again the whole connection is replaced: a "Waiting for video" that never ends is
     * worse than a reconnect. A refused lane key is the lane's own failure and never gets here.
     */
    fun takeEscalation(): PictureEscalation {
        if (seen || lane?.failure != null) return PictureEscalation.NONE
        val waited = clock.monotonicSeconds() - waitingSince
        if (waited >= GIVE_UP_SECONDS) {
            return if (automaticRestarts == 0) PictureEscalation.REOPEN else PictureEscalation.RECONNECT
        }
        if (automaticNudges >= MAX_AUTOMATIC_NUDGES || waited < STALL_SECONDS * (automaticNudges + 1)) return PictureEscalation.NONE
        automaticNudges += 1
        return PictureEscalation.KEYFRAME
    }

    fun start(scope: CoroutineScope) {
        this.scope = scope
        job?.cancel()
        job = lane?.let {
            it.reset()
            scope.launch { it.run() }
        }
    }

    /** Forgets the picture seen so far, so the area reads as waiting again, and reopens the lane from the first rung. A person asking starts the escalation over; the watch reopening it for itself does not. */
    fun restart(automatic: Boolean = false) {
        seen = false
        automaticNudges = 0
        automaticRestarts = if (automatic) automaticRestarts + 1 else 0
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
        const val GIVE_UP_SECONDS = 30.0
    }
}
