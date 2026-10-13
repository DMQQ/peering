package pl.dmq.peering.wire

import kotlin.math.hypot

sealed class PointerAction {
    data class MoveTo(val nx: Double, val ny: Double) : PointerAction()

    data class ButtonDown(val button: MouseButton) : PointerAction()

    data class ButtonUp(val button: MouseButton) : PointerAction()

    data class Click(val button: MouseButton) : PointerAction()

    data class Scroll(val dx: Double, val dy: Double) : PointerAction()
}

/**
 * Turns touch samples into pointer actions for a canvas of [canvasWidth] by [canvasHeight] pixels. Trackpad calls move
 * a virtual cursor by finger deltas, direct calls put it under the finger. Time arrives with each call so the model
 * never reads a clock. Not thread safe.
 */
class TrackpadModel(
    private val canvasWidth: Double,
    private val canvasHeight: Double,
    private val sensitivity: Double = 1.0,
) {
    init {
        require(canvasWidth > 0 && canvasHeight > 0) { "canvas must have a positive size" }
    }

    var cursorX: Double = 0.5
        private set
    var cursorY: Double = 0.5
        private set

    private var travelWidth = canvasWidth
    private var travelHeight = canvasHeight

    private val touches = LinkedHashMap<Int, Touch>()
    private var gestureStartMs = 0L
    private var gestureFingers = 0
    private var gestureTravelled = false
    private var dragging = false

    /** Sets the pixels a finger crosses to sweep the cursor over the whole picture, one per axis. The default is the canvas. */
    fun sweep(width: Double, height: Double) {
        if (width <= 0 || height <= 0) return
        travelWidth = width
        travelHeight = height
    }

    /** Puts the cursor where the computer's pointer really is, so the next drag starts from there. Sends nothing. */
    fun syncCursor(x: Double, y: Double) {
        cursorX = x.coerceIn(0.0, 1.0)
        cursorY = y.coerceIn(0.0, 1.0)
    }

    fun onDown(id: Int, x: Double, y: Double, timeMs: Long): List<PointerAction> {
        if (touches.isEmpty()) startGesture(timeMs)
        touches[id] = Touch(x, y, timeMs)
        gestureFingers = maxOf(gestureFingers, touches.size)
        if (touches.size < 2 || !dragging) return emptyList()
        dragging = false
        return listOf(PointerAction.ButtonUp(MouseButton.LEFT))
    }

    fun onMove(id: Int, x: Double, y: Double, timeMs: Long): List<PointerAction> {
        val touch = touches[id] ?: return emptyList()
        val priorTravel = touch.maxTravel
        val dx = x - touch.lastX
        val dy = y - touch.lastY
        touch.moveTo(x, y)
        if (touch.maxTravel > TAP_SLOP_PX) gestureTravelled = true
        if (touches.size > 1) return listOf(PointerAction.Scroll(dx, dy))
        val actions = mutableListOf<PointerAction>()
        if (!dragging && timeMs - touch.downTime >= LONG_PRESS_MS && priorTravel <= TAP_SLOP_PX) {
            dragging = true
            actions += PointerAction.ButtonDown(MouseButton.LEFT)
        }
        actions += moveCursor(dx, dy)
        return actions
    }

    fun onUp(id: Int, x: Double, y: Double, timeMs: Long): List<PointerAction> {
        val touch = touches.remove(id) ?: return emptyList()
        touch.moveTo(x, y)
        if (touch.maxTravel > TAP_SLOP_PX) gestureTravelled = true
        val actions = mutableListOf<PointerAction>()
        if (dragging) {
            dragging = false
            actions += PointerAction.ButtonUp(MouseButton.LEFT)
        }
        if (touches.isEmpty()) {
            tapAction(timeMs)?.let { actions += it }
            gestureFingers = 0
        }
        return actions
    }

    fun onDirectDown(x: Double, y: Double): List<PointerAction> =
        listOf(placeCursor(x, y), PointerAction.ButtonDown(MouseButton.LEFT))

    fun onDirectMove(x: Double, y: Double): List<PointerAction> = listOf(placeCursor(x, y))

    fun onDirectUp(x: Double, y: Double): List<PointerAction> =
        listOf(placeCursor(x, y), PointerAction.ButtonUp(MouseButton.LEFT))

    private fun startGesture(timeMs: Long) {
        gestureStartMs = timeMs
        gestureFingers = 0
        gestureTravelled = false
    }

    private fun moveCursor(dx: Double, dy: Double): PointerAction.MoveTo {
        cursorX = (cursorX + dx / travelWidth * sensitivity).coerceIn(0.0, 1.0)
        cursorY = (cursorY + dy / travelHeight * sensitivity).coerceIn(0.0, 1.0)
        return PointerAction.MoveTo(cursorX, cursorY)
    }

    private fun placeCursor(x: Double, y: Double): PointerAction.MoveTo {
        cursorX = (x / canvasWidth).coerceIn(0.0, 1.0)
        cursorY = (y / canvasHeight).coerceIn(0.0, 1.0)
        return PointerAction.MoveTo(cursorX, cursorY)
    }

    private fun tapAction(timeMs: Long): PointerAction? {
        if (gestureTravelled || timeMs - gestureStartMs > TAP_MAX_MS) return null
        return when (gestureFingers) {
            1 -> PointerAction.Click(MouseButton.LEFT)
            2 -> PointerAction.Click(MouseButton.RIGHT)
            else -> null
        }
    }

    private class Touch(private val downX: Double, private val downY: Double, val downTime: Long) {
        var lastX: Double = downX
            private set
        var lastY: Double = downY
            private set
        var maxTravel: Double = 0.0
            private set

        fun moveTo(x: Double, y: Double) {
            lastX = x
            lastY = y
            maxTravel = maxOf(maxTravel, hypot(x - downX, y - downY))
        }
    }

    private companion object {
        const val TAP_SLOP_PX = 10.0
        const val TAP_MAX_MS = 250L
        const val LONG_PRESS_MS = 400L
    }
}
