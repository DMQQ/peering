package pl.dmq.peering.session.video

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.MosaicTile
import pl.dmq.peering.wire.NormalizedRect
import pl.dmq.peering.wire.PixelSize

/** Arranging tiles on the phone: how many columns, where each sits, and how big a canvas to ask the Mac for. */
object MosaicGrid {
    const val DEFAULT_FRAME_RATE = 15
    const val WINDOW_ASPECT = 1.6
    const val MINIMUM_TILES = 2
    private const val MAXIMUM_CANVAS_PIXELS = 2560.0 * 1440.0
    private const val MINIMUM_ASPECT = 0.5
    private const val MAXIMUM_ASPECT = 3.0

    fun columns(count: Int, portrait: Boolean): Int {
        if (count <= 1) return 1
        val root = sqrt(count.toDouble())
        val rounded = if (portrait) floor(root) else ceil(root)
        return max(1, min(rounded.toInt(), count))
    }

    /** Every tile the same size, in reading order; a short last row ends early. */
    fun rects(count: Int, portrait: Boolean): List<NormalizedRect> {
        if (count <= 0) return emptyList()
        val columns = columns(count, portrait)
        val rows = ceil(count.toDouble() / columns).toInt()
        val width = 1.0 / columns
        val height = 1.0 / rows
        return List(count) { index -> NormalizedRect(width * (index % columns), height * (index / columns), width, height) }
    }

    /** The median shape of the sources the catalogue describes, so one odd window does not shape the grid. */
    fun tileAspect(sources: List<CaptureSource>, catalog: CaptureCatalog?): Double {
        val known = catalog ?: return WINDOW_ASPECT
        val everything = known.displays + known.applications + known.windows
        val aspects = sources
            .mapNotNull { source -> everything.firstOrNull { it.source == source }?.pixelSize }
            .filter { it.width > 0 && it.height > 0 }
            .map { it.width / it.height }
            .sorted()
        if (aspects.isEmpty()) return WINDOW_ASPECT
        return aspects[aspects.size / 2].coerceIn(MINIMUM_ASPECT, MAXIMUM_ASPECT)
    }

    /** The canvas to ask for: the shape of the arrangement at the screen's own pixels, within the host's pixel budget. */
    fun canvas(columns: Int, tiles: Int, tileAspect: Double, viewport: PixelSize): PixelSize {
        val rows = ceil(max(tiles, 1).toDouble() / max(columns, 1))
        val aspect = (max(columns, 1) / rows * tileAspect).coerceIn(0.05, 20.0)
        var width = min(viewport.width, viewport.height * aspect)
        var height = width / aspect
        val area = width * height
        if (area > MAXIMUM_CANVAS_PIXELS) {
            val scale = sqrt(MAXIMUM_CANVAS_PIXELS / area)
            width *= scale
            height *= scale
        }
        return PixelSize(even(width), even(height))
    }

    /** The layout for [sources] on a screen of [viewport] pixels, or null when fewer than two or more than the host builds. */
    fun layout(sources: List<CaptureSource>, viewport: PixelSize, catalog: CaptureCatalog?): MosaicLayout? {
        if (sources.size < MINIMUM_TILES || sources.size > MosaicLayout.MAXIMUM_TILES) return null
        val portrait = viewport.height > viewport.width
        val columns = columns(sources.size, portrait)
        val tiles = sources.zip(rects(sources.size, portrait)).map { (source, rect) -> MosaicTile(source, rect) }
        val canvas = canvas(columns, sources.size, tileAspect(sources, catalog), viewport)
        return MosaicLayout(canvas, tiles, DEFAULT_FRAME_RATE)
    }

    private fun even(value: Double): Double = max(2.0, floor(value / 2) * 2)
}
