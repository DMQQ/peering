package pl.dmq.peering.feature.sessionmode

import kotlin.math.hypot
import pl.dmq.peering.feature.remote.RemoteCanvasPresenter

/**
 * Sits between the pad's fingers and the trackpad presenter: turns each position by how the phone is held, takes three
 * or four fingers away from the presenter as a swipe, and notices a plain tap for the ripple. Positions are pad pixels.
 * Not thread safe: events arrive in order from one thread.
 */
class TrackpadGestures(
    private val pad: RemoteCanvasPresenter,
    private val swipeMinimumPx: Double,
    private val tapSlopPx: Double,
    private val onSwipe: (TrackpadSwipe) -> Unit,
) {
    /** Called with where a plain one finger tap landed, unturned. */
    var onTapped: ((x: Double, y: Double) -> Unit)? = null
    var orientation = TrackpadOrientation(0)
    private val fingers = LinkedHashMap<Int, Pair<Double, Double>>()
    private var swiping = false
    private var travelX = 0.0
    private var travelY = 0.0
    private var tapStart: Pair<Double, Double>? = null
    private var tapStartMs = 0L

    /** When a finger last moved the pointer, in the event clock, or null before any did. */
    var lastMoveMs: Long? = null
        private set

    val fingerDown: Boolean get() = fingers.isNotEmpty()

    /**
     * Whether a pointer report from the host may replace where the pad thinks the pointer is. A report lags the moves the
     * pad just sent, so taking one mid swipe snapped the pointer back: only one that arrives while the pad is idle counts.
     */
    fun adoptsHostPointer(nowMs: Long): Boolean {
        if (fingerDown) return false
        val lastMove = lastMoveMs ?: return true
        return nowMs - lastMove >= ADOPT_AFTER_MS
    }

    /** The first finger on the pad, unturned, for the dots to gather round. */
    val touch: Pair<Double, Double>? get() = fingers.values.firstOrNull()

    fun down(id: Int, x: Double, y: Double, timeMs: Long) {
        fingers[id] = x to y
        tapStart = if (fingers.size == 1) x to y else null
        tapStartMs = timeMs
        if (swiping) return
        if (fingers.size >= SWIPE_FINGERS) {
            swiping = true
            travelX = 0.0
            travelY = 0.0
            pad.cancelPointers()
            return
        }
        val (turnedX, turnedY) = orientation.intended(x, y)
        pad.onPointerDown(id, turnedX, turnedY, timeMs)
    }

    fun move(id: Int, x: Double, y: Double, timeMs: Long) {
        val previous = fingers[id] ?: return
        fingers[id] = x to y
        if (swiping) {
            travelX += (x - previous.first) / fingers.size
            travelY += (y - previous.second) / fingers.size
            return
        }
        lastMoveMs = timeMs
        val (turnedX, turnedY) = orientation.intended(x, y)
        pad.onPointerMove(id, turnedX, turnedY, timeMs)
    }

    fun up(id: Int, x: Double, y: Double, timeMs: Long) {
        if (fingers.remove(id) == null) return
        if (swiping) {
            if (fingers.isEmpty()) finishSwipe()
            return
        }
        val (turnedX, turnedY) = orientation.intended(x, y)
        pad.onPointerUp(id, turnedX, turnedY, timeMs)
        val start = tapStart
        if (fingers.isEmpty() && start != null && timeMs - tapStartMs <= TAP_MAX_MS && hypot(x - start.first, y - start.second) <= tapSlopPx) {
            onTapped?.invoke(x, y)
        }
    }

    /** The pad went away or the system took the touch: no click, and a held drag lets go. */
    fun cancel() {
        fingers.clear()
        swiping = false
        pad.cancelPointers()
    }

    private fun finishSwipe() {
        swiping = false
        val (dx, dy) = orientation.intended(travelX, travelY)
        TrackpadSwipe.of(dx, dy, swipeMinimumPx)?.let(onSwipe)
    }

    private companion object {
        const val SWIPE_FINGERS = 3
        const val TAP_MAX_MS = 250L
        const val ADOPT_AFTER_MS = 500L
    }
}
