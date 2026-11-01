package pl.dmq.peering.feature.remote

import kotlin.math.hypot
import pl.dmq.peering.feature.sessionmode.TrackpadSwipe

/**
 * Reads the gestures made on the picture itself: a held finger and a two finger tap both mean a right click, and three
 * or four fingers swipe between desktops. Distances are canvas pixels, scaled by [pixelsPerDp]. Times come with each
 * call so the class never reads a clock. Not thread safe.
 */
class PictureGestures {
    sealed interface Outcome {
        data class SecondaryClick(val at: CanvasPoint) : Outcome

        data class Swipe(val direction: TrackpadSwipe) : Outcome
    }

    var pixelsPerDp = 1.0
    private val fingers = LinkedHashMap<Int, CanvasPoint>()
    private val starts = HashMap<Int, CanvasPoint>()
    private var firstDown = CanvasPoint(0.0, 0.0)
    private var startMs = 0L
    private var peakFingers = 0
    private var held = false
    private var travelX = 0.0
    private var travelY = 0.0

    /** A finger has moved beyond the tap slop since the gesture began. */
    var travelled = false
        private set

    /** Three or more fingers have touched since the gesture began, so nothing else may act on it until all lift. */
    val swiping: Boolean get() = peakFingers >= SWIPE_FINGERS

    /** The single finger was held still long enough to count as a right click, so the rest of that touch is spent. */
    val spent: Boolean get() = held

    fun down(id: Int, x: Double, y: Double, timeMs: Long) {
        if (fingers.isEmpty()) {
            starts.clear()
            firstDown = CanvasPoint(x, y)
            startMs = timeMs
            peakFingers = 0
            held = false
            travelled = false
            travelX = 0.0
            travelY = 0.0
        }
        fingers[id] = CanvasPoint(x, y)
        starts[id] = CanvasPoint(x, y)
        peakFingers = maxOf(peakFingers, fingers.size)
    }

    fun move(id: Int, x: Double, y: Double) {
        val previous = fingers[id] ?: return
        fingers[id] = CanvasPoint(x, y)
        if (swiping) {
            travelX += (x - previous.x) / fingers.size
            travelY += (y - previous.y) / fingers.size
        }
        val start = starts[id] ?: return
        if (hypot(x - start.x, y - start.y) > TAP_SLOP_DP * pixelsPerDp) travelled = true
    }

    /** Returns what the gesture amounted to once its last finger lifts, or null when it was none of these. */
    fun up(id: Int, timeMs: Long): Outcome? {
        if (fingers.remove(id) == null || fingers.isNotEmpty()) return null
        return when {
            swiping -> TrackpadSwipe.of(travelX, travelY, SWIPE_MINIMUM_DP * pixelsPerDp)?.let(Outcome::Swipe)
            peakFingers == 2 && !travelled && timeMs - startMs <= TAP_MAX_MS -> Outcome.SecondaryClick(firstDown)
            else -> null
        }
    }

    /** Milliseconds until the one finger down counts as held, or null when no hold is pending. */
    fun holdRemaining(nowMs: Long): Long? {
        if (fingers.size != 1 || peakFingers != 1 || travelled || held) return null
        return (startMs + HOLD_MS - nowMs).coerceAtLeast(0)
    }

    /** The hold time passed: returns where the finger is held, or null when no hold was pending. */
    fun holdElapsed(nowMs: Long): CanvasPoint? {
        val remaining = holdRemaining(nowMs) ?: return null
        if (remaining > 0) return null
        held = true
        return firstDown
    }

    fun cancel() {
        fingers.clear()
        peakFingers = 0
    }

    private companion object {
        const val SWIPE_FINGERS = 3
        const val TAP_SLOP_DP = 10.0
        const val SWIPE_MINIMUM_DP = 40.0
        const val TAP_MAX_MS = 250L
        const val HOLD_MS = 500L
    }
}
