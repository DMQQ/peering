package pl.dmq.peering.feature.remote

import kotlin.math.hypot

/** Tells a tap from a drag or a pinch: one finger, down and up close together in place and in time. */
class MosaicTapDetector {
    private var candidate: Int? = null
    private var startX = 0.0
    private var startY = 0.0
    private var startTime = 0L
    private var cancelled = false

    /** [fingers] counts every finger down including this one. */
    fun down(id: Int, x: Double, y: Double, timeMs: Long, fingers: Int) {
        if (fingers > 1) {
            cancelled = true
            return
        }
        candidate = id
        startX = x
        startY = y
        startTime = timeMs
        cancelled = false
    }

    fun move(id: Int, x: Double, y: Double) {
        if (id == candidate && hypot(x - startX, y - startY) > SLOP) cancelled = true
    }

    /** True when this lift completes a tap. [remaining] counts the fingers still down. */
    fun up(id: Int, x: Double, y: Double, timeMs: Long, remaining: Int): Boolean {
        val tap = id == candidate && !cancelled &&
            hypot(x - startX, y - startY) <= SLOP && timeMs - startTime <= MAX_TAP_MS
        if (remaining == 0) {
            candidate = null
            cancelled = false
        }
        return tap
    }

    private companion object {
        const val SLOP = 18.0
        const val MAX_TAP_MS = 400L
    }
}
