package pl.dmq.peering.feature.remote

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.min

/** What one notch of the wheel is worth: 12 points of finger travel, 24 pixels of document, about a line of text. */
object ScrollNotch {
    const val TRAVEL = 12.0
    const val PIXELS_PER_POINT = 2.0
    const val PIXELS = TRAVEL * PIXELS_PER_POINT
}

/**
 * The wheel's detents. Finger travel accumulates and only whole notches are delivered, so a shaky drag scrolls as far as
 * a steady one. Not thread safe.
 */
class ScrollWheelState {
    private var carry = 0.0

    var delivered = 0
        private set

    /** Continuous, so the rim can turn smoothly while only whole notches are sent. */
    val phase: Double get() = delivered + carry / ScrollNotch.TRAVEL

    /** Adds [points] of finger travel and returns the whole notches it completed, negative when rolling back. */
    fun roll(points: Double): Int {
        carry += points
        var whole = 0
        while (carry >= ScrollNotch.TRAVEL) {
            carry -= ScrollNotch.TRAVEL
            whole += 1
        }
        while (carry <= -ScrollNotch.TRAVEL) {
            carry += ScrollNotch.TRAVEL
            whole -= 1
        }
        delivered += whole
        return whole
    }

    fun rollNotches(notches: Double): Int = roll(notches * ScrollNotch.TRAVEL)

    /** The detent spring, run when the finger leaves: moves at most half a notch, so the wheel ends on a whole one. */
    fun seat(): Int {
        val half = ScrollNotch.TRAVEL / 2
        val whole = when {
            carry > half -> delivered + 1
            carry < -half -> delivered - 1
            else -> delivered
        }
        carry = 0.0
        val moved = whole - delivered
        delivered = whole
        return moved
    }
}

/** The coast after a flick: an exponential decay in notches per second, capped so a flick cannot carry a whole document. */
object WheelSpin {
    const val LAUNCH_LIMIT = 120.0
    const val DECAY = 0.35

    /** Below this rate the wheel counts as stopped. */
    const val STALLING = 1.5

    fun launch(pointsPerSecond: Double): Double = min(pointsPerSecond / ScrollNotch.TRAVEL, LAUNCH_LIMIT)

    fun rate(launch: Double, afterSeconds: Double): Double = launch * exp(-afterSeconds / DECAY)

    fun duration(launch: Double): Double = if (launch > STALLING) DECAY * ln(launch / STALLING) else 0.0
}
