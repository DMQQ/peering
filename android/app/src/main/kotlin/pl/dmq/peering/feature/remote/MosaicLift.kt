package pl.dmq.peering.feature.remote

import kotlin.math.hypot

/** Tells a held press from a tap or a pan, and follows the tile it lifted until the finger is let go. */
class MosaicLift {
    private var candidate: Int? = null
    private var holder: Int? = null
    private var startX = 0.0
    private var startY = 0.0
    private var startTime = 0L

    var drag: MosaicDrag? = null
        private set

    /** [fingers] counts every finger down including this one; a second one means a pinch, not a lift. */
    fun down(id: Int, x: Double, y: Double, timeMs: Long, fingers: Int) {
        if (fingers > 1) {
            cancel()
            return
        }
        candidate = id
        startX = x
        startY = y
        startTime = timeMs
    }

    /** A press that has moved off its spot is a pan. */
    fun moved(id: Int, x: Double, y: Double) {
        if (id == candidate && hypot(x - startX, y - startY) > SLOP) candidate = null
    }

    /** Milliseconds until the waiting press counts as held, or null when none is waiting. */
    fun remaining(nowMs: Long): Long? = candidate?.let { (startTime + HOLD_MS - nowMs).coerceAtLeast(0) }

    fun waitingPoint(): CanvasPoint? = candidate?.let { CanvasPoint(startX, startY) }

    /** Lifts tile [index] under the waiting press. False when no press is waiting. */
    fun lift(index: Int): Boolean {
        val id = candidate ?: return false
        holder = id
        candidate = null
        drag = MosaicDrag(index, index, startX, startY)
        return true
    }

    fun holds(id: Int): Boolean = id == holder

    /** Moves the lifted tile to ([x], [y]); [over] is the tile under the finger, or null over a seam, which keeps the last target. */
    fun follow(x: Double, y: Double, over: Int?) {
        drag = drag?.let { it.copy(x = x, y = y, target = over ?: it.target) }
    }

    /** Ends the lift and returns what was carried, or null when [id] was not carrying anything. */
    fun release(id: Int): MosaicDrag? {
        if (id == candidate) candidate = null
        if (id != holder) return null
        return drag.also { cancel() }
    }

    fun cancel() {
        candidate = null
        holder = null
        drag = null
    }

    companion object {
        const val HOLD_MS = 450L
        private const val SLOP = 18.0
    }
}
