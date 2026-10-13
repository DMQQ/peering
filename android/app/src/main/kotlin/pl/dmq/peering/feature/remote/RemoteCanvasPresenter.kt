package pl.dmq.peering.feature.remote

import kotlin.math.abs
import kotlin.math.hypot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.PointerAction
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.TrackpadModel

/**
 * Turns pointer events on the canvas into commands for the Mac. One finger drives the cursor (trackpad) or places it
 * on the picture (direct). Two fingers either pinch to zoom the view, or scroll the Mac when they do not pinch.
 * Pointer positions are canvas pixels. Not thread safe: the caller delivers events in order from one thread.
 */
class RemoteCanvasPresenter(
    private val sink: CommandSink,
    mode: InputMode,
    private val cursor: () -> NormalizedPoint = { NormalizedPoint(0.5, 0.5) },
) {
    private val uiState = MutableStateFlow(CanvasUiState.INITIAL)
    val state: StateFlow<CanvasUiState> = uiState.asStateFlow()

    private var mode = mode
    private var mosaic: MosaicLayout? = null
    private val taps = MosaicTapDetector()
    private val lift = MosaicLift()

    /** Called with the source of the tile a tap landed on while a mosaic is up. */
    var onTileTapped: ((CaptureSource) -> Unit)? = null

    /** Called when a lifted tile is dropped on another place, with the place it came from and the one it went to. */
    var onTileMoved: ((from: Int, to: Int) -> Unit)? = null
    private var canvas: CanvasSize? = null
    private var trackpad: TrackpadModel? = null
    private var picture: PixelSize? = null
    private var viewport = CanvasViewport()
    private val pointers = LinkedHashMap<Int, CanvasPoint>()
    private var pinching = false
    private var startSpread = 0.0
    private var lastSpread = 0.0
    private var lastCentroid = CanvasPoint(0.0, 0.0)
    private var directPressed = false
    private var lastDirectPoint = NormalizedPoint(0.5, 0.5)

    fun setMode(next: InputMode) {
        if (next == mode) return
        releaseDirect(lastDirectPoint)
        mode = next
    }

    /** While a mosaic is up the canvas only views: one finger pans, two zoom, and a tap on a tile opens that tile. */
    fun setMosaic(next: MosaicLayout?) {
        if (next == mosaic) return
        releaseDirect(lastDirectPoint)
        mosaic = next
        lift.cancel()
        publish()
    }

    /** Milliseconds until a press on a tile counts as held, or null when none is waiting. */
    fun holdRemaining(nowMs: Long): Long? = if (mosaic != null) lift.remaining(nowMs) else null

    /** The waiting press has been held long enough: lifts the tile under it. True when one was lifted. */
    fun onHoldElapsed(): Boolean {
        val at = lift.waitingPoint() ?: return false
        val index = tileAt(at.x, at.y) ?: return false
        return lift.lift(index).also { if (it) publish() }
    }

    private val effectiveMode: InputMode get() = if (mosaic != null) InputMode.OBSERVE else mode

    fun onCanvasSized(width: Double, height: Double) {
        if (width <= 0 || height <= 0) return
        val size = CanvasSize(width, height)
        if (size == canvas) return
        releaseDirect(lastDirectPoint)
        canvas = size
        trackpad = TrackpadModel(width, height)
        pointers.clear()
        lift.cancel()
        pinching = false
        viewport = viewport.pannedBy(0.0, 0.0, size)
        publish()
    }

    fun onPictureChanged(next: PixelSize?) {
        picture = next
        publish()
    }

    /** Returns the view to fitted and unzoomed, as the fit control does. */
    fun fitToCanvas() {
        viewport = CanvasViewport()
        publish()
    }

    /** Zooms until the picture covers the whole canvas, as far as the zoom limit allows, about the canvas centre. */
    fun fillCanvas() {
        val size = canvas ?: return
        val fit = fittedPicture() ?: return
        val cover = maxOf(size.width / fit.width, size.height / fit.height)
        viewport = CanvasViewport().zoomedAbout(cover, size.width / 2, size.height / 2, size)
        publish()
    }

    /** One wheel notch of zoom about the canvas centre, positive zooming in. */
    fun zoomByNotch(notches: Int) {
        val size = canvas ?: return
        viewport = viewport.zoomedAbout(Math.pow(NOTCH_ZOOM, notches.toDouble()), size.width / 2, size.height / 2, size)
        publish()
    }

    fun onPointerDown(id: Int, x: Double, y: Double, timeMs: Long) {
        val model = trackpad ?: return
        pointers[id] = CanvasPoint(x, y)
        if (mosaic != null) {
            taps.down(id, x, y, timeMs, pointers.size)
            if (pointers.size > 1 && lift.drag != null) {
                lift.cancel()
                publish()
            }
            lift.down(id, x, y, timeMs, pointers.size)
        }
        when {
            effectiveMode == InputMode.TRACKPAD -> {
                if (pointers.size == 1) cursor().let { model.syncCursor(it.x, it.y) }
                emit(model.onDown(id, x, y, timeMs))
            }
            effectiveMode == InputMode.DIRECT && pointers.size == 1 -> pressDirect(x, y)
        }
        if (pointers.size >= 2) releaseDirect(lastDirectPoint)
        rebaseline()
    }

    fun onPointerMove(id: Int, x: Double, y: Double, timeMs: Long) {
        val model = trackpad ?: return
        val previous = pointers[id] ?: return
        pointers[id] = CanvasPoint(x, y)
        if (mosaic != null) {
            taps.move(id, x, y)
            lift.moved(id, x, y)
        }
        if (lift.holds(id)) {
            lift.follow(x, y, tileAt(x, y))
            publish()
            return
        }
        if (pointers.size >= 2) multiTouchFrame()?.let(::applyMultiTouch)
        when {
            effectiveMode == InputMode.OBSERVE -> if (pointers.size == 1) panBy(x - previous.x, y - previous.y)
            effectiveMode == InputMode.TRACKPAD -> {
                val actions = model.onMove(id, x, y, timeMs)
                if (!pinching) emit(actions)
            }
            pointers.size == 1 && directPressed -> moveDirect(x, y)
        }
    }

    fun onPointerUp(id: Int, x: Double, y: Double, timeMs: Long) {
        val model = trackpad ?: return
        if (pointers.remove(id) == null) return
        if (lift.holds(id)) {
            drop(id)
            rebaseline()
            return
        }
        if (mosaic != null) lift.release(id)
        if (mosaic != null && taps.up(id, x, y, timeMs, pointers.size)) openTileAt(x, y)
        when {
            effectiveMode == InputMode.TRACKPAD -> emit(model.onUp(id, x, y, timeMs))
            effectiveMode == InputMode.DIRECT && pointers.isEmpty() -> releaseDirect(directPoint(x, y) ?: lastDirectPoint)
        }
        rebaseline()
    }

    private fun tileAt(x: Double, y: Double): Int? {
        val layout = mosaic ?: return null
        val fit = fittedPicture() ?: return null
        return MosaicHit.tileAt(layout, viewport, fit, x, y)
    }

    /** One ask when the finger lifts, not one per seam it crossed: the order only settles when it is let go. */
    private fun drop(id: Int) {
        val carried = lift.release(id)
        publish()
        if (carried != null && carried.held != carried.target) onTileMoved?.invoke(carried.held, carried.target)
    }

    private fun openTileAt(x: Double, y: Double) {
        val index = tileAt(x, y) ?: return
        val layout = mosaic ?: return
        onTileTapped?.invoke(layout.tiles[index].source)
    }

    private data class MultiTouchFrame(val centroid: CanvasPoint, val spread: Double)

    /** Mean distance from the centroid, so the spread ratio between two frames is the zoom factor. */
    private fun multiTouchFrame(): MultiTouchFrame? {
        val points = pointers.values
        val count = points.size.toDouble()
        val centroid = CanvasPoint(points.sumOf { it.x } / count, points.sumOf { it.y } / count)
        val spread = points.sumOf { hypot(it.x - centroid.x, it.y - centroid.y) } / count
        return if (spread > 0) MultiTouchFrame(centroid, spread) else null
    }

    private fun applyMultiTouch(frame: MultiTouchFrame) {
        if (!pinching && abs(frame.spread / startSpread - 1) > PINCH_THRESHOLD) pinching = true
        if (pinching) {
            zoomAndPan(frame)
        } else if (effectiveMode == InputMode.DIRECT) {
            sink.send(Scroll(frame.centroid.x - lastCentroid.x, frame.centroid.y - lastCentroid.y))
        } else if (effectiveMode == InputMode.OBSERVE) {
            panBy(frame.centroid.x - lastCentroid.x, frame.centroid.y - lastCentroid.y)
        }
        lastSpread = frame.spread
        lastCentroid = frame.centroid
    }

    private fun panBy(dx: Double, dy: Double) {
        val size = canvas ?: return
        viewport = viewport.pannedBy(dx, dy, size)
        publish()
    }

    private fun zoomAndPan(frame: MultiTouchFrame) {
        val size = canvas ?: return
        viewport = viewport
            .zoomedAbout(frame.spread / lastSpread, frame.centroid.x, frame.centroid.y, size)
            .pannedBy(frame.centroid.x - lastCentroid.x, frame.centroid.y - lastCentroid.y, size)
        publish()
    }

    /** Starts a new pinch baseline whenever the set of touching fingers changes. */
    private fun rebaseline() {
        pinching = false
        if (pointers.size < 2) return
        val frame = multiTouchFrame() ?: return
        startSpread = frame.spread
        lastSpread = frame.spread
        lastCentroid = frame.centroid
    }

    private fun pressDirect(x: Double, y: Double) {
        val model = trackpad ?: return
        val point = directPoint(x, y) ?: return
        directPressed = true
        lastDirectPoint = point
        val (unitX, unitY) = modelUnits(point)
        emit(model.onDirectDown(unitX, unitY))
    }

    private fun moveDirect(x: Double, y: Double) {
        val model = trackpad ?: return
        val point = directPoint(x, y) ?: lastDirectPoint
        lastDirectPoint = point
        val (unitX, unitY) = modelUnits(point)
        emit(model.onDirectMove(unitX, unitY))
    }

    private fun releaseDirect(point: NormalizedPoint) {
        val model = trackpad ?: return
        if (!directPressed) return
        directPressed = false
        val (unitX, unitY) = modelUnits(point)
        emit(model.onDirectUp(unitX, unitY))
    }

    /** The picture point under a canvas point, or null while no picture is fitted. */
    private fun directPoint(x: Double, y: Double): NormalizedPoint? {
        val fit = fittedPicture() ?: return null
        return viewport.canvasToPicture(x, y, fit)
    }

    private fun fittedPicture(): CanvasRect? {
        val size = canvas ?: return null
        val pixels = picture ?: return null
        return aspectFitRect(pixels, size)
    }

    /**
     * TrackpadModel's direct calls take canvas pixels and divide by the canvas size. The picture point is handed back
     * in canvas units so that division lands on the same fraction.
     */
    private fun modelUnits(point: NormalizedPoint): Pair<Double, Double> {
        val size = canvas ?: return 0.0 to 0.0
        return point.x * size.width to point.y * size.height
    }

    private fun publish() {
        val shown = fittedPicture()?.let(viewport::displayed)
        if (shown != null) trackpad?.sweep(shown.width, shown.height)
        uiState.value = CanvasUiState(viewport, shown, lift.drag)
    }

    private fun emit(actions: List<PointerAction>) {
        actions.flatMap { it.toCommands() }.forEach(sink::send)
    }

    private companion object {
        const val PINCH_THRESHOLD = 0.05
        const val NOTCH_ZOOM = 1.03
    }
}
