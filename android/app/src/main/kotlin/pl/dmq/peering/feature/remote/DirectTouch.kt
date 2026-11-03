package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PointerAction
import pl.dmq.peering.wire.TrackpadModel

/**
 * Direct mode's one finger: the button goes down where the finger landed only once it moves or lifts, so a finger held
 * still can become a right click instead. Positions are canvas pixels. Not thread safe.
 */
internal class DirectTouch(
    private val model: () -> TrackpadModel?,
    private val toPicture: (x: Double, y: Double) -> NormalizedPoint?,
    private val toUnits: (NormalizedPoint) -> Pair<Double, Double>,
    private val emit: (List<PointerAction>) -> Unit,
) {
    var pending: CanvasPoint? = null
        private set
    private var pressed = false
    private var lastPoint = NormalizedPoint(0.5, 0.5)

    fun touched(x: Double, y: Double) {
        pending = CanvasPoint(x, y)
    }

    /** Forgets an unpressed touch without clicking. */
    fun forget() {
        pending = null
    }

    /** Forgets an unpressed touch and releases a pressed one where it last was. */
    fun letGo() {
        pending = null
        releaseAt(lastPoint)
    }

    fun moved(x: Double, y: Double, travelled: Boolean) {
        val start = pending
        if (start != null && travelled) {
            pending = null
            press(start.x, start.y)
        }
        if (!pressed) return
        val target = model() ?: return
        val point = toPicture(x, y) ?: lastPoint
        lastPoint = point
        val (unitX, unitY) = toUnits(point)
        emit(target.onDirectMove(unitX, unitY))
    }

    /** An unmoved touch that lifts is a click where it landed. */
    fun lifted(x: Double, y: Double) {
        val start = pending
        pending = null
        if (start != null) press(start.x, start.y)
        releaseAt(toPicture(x, y) ?: lastPoint)
    }

    /** Puts the cursor at [at] and right clicks there. False while no picture is fitted. */
    fun rightClick(at: CanvasPoint): Boolean {
        val target = model() ?: return false
        val point = toPicture(at.x, at.y) ?: return false
        pending = null
        val (unitX, unitY) = toUnits(point)
        emit(target.onDirectMove(unitX, unitY) + PointerAction.Click(MouseButton.RIGHT))
        return true
    }

    private fun press(x: Double, y: Double) {
        val target = model() ?: return
        val point = toPicture(x, y) ?: return
        pressed = true
        lastPoint = point
        val (unitX, unitY) = toUnits(point)
        emit(target.onDirectDown(unitX, unitY))
    }

    private fun releaseAt(point: NormalizedPoint) {
        val target = model() ?: return
        if (!pressed) return
        pressed = false
        val (unitX, unitY) = toUnits(point)
        emit(target.onDirectUp(unitX, unitY))
    }
}
