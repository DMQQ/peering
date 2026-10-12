package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.NormalizedPoint

/**
 * Pinch zoom and pan of the canvas. The content is the canvas scaled by [zoom] from its top left corner and then moved
 * by ([panX], [panY]). Pan is clamped so the content always covers the canvas.
 */
data class CanvasViewport(
    val zoom: Double = MIN_ZOOM,
    val panX: Double = 0.0,
    val panY: Double = 0.0,
) {
    /** Zooms by [factor] while keeping the canvas point under ([focusX], [focusY]) where it is. */
    fun zoomedAbout(factor: Double, focusX: Double, focusY: Double, canvas: CanvasSize): CanvasViewport {
        val nextZoom = (zoom * factor).coerceIn(MIN_ZOOM, MAX_ZOOM)
        val ratio = nextZoom / zoom
        return clampedTo(
            zoom = nextZoom,
            panX = focusX - (focusX - panX) * ratio,
            panY = focusY - (focusY - panY) * ratio,
            canvas = canvas,
        )
    }

    fun pannedBy(dx: Double, dy: Double, canvas: CanvasSize): CanvasViewport =
        clampedTo(zoom, panX + dx, panY + dy, canvas)

    /** Where the fitted picture [fit] (in unzoomed canvas pixels) is drawn on screen. */
    fun displayed(fit: CanvasRect): CanvasRect = CanvasRect(
        left = panX + fit.left * zoom,
        top = panY + fit.top * zoom,
        width = fit.width * zoom,
        height = fit.height * zoom,
    )

    /** Maps a screen point on the canvas to a fraction of the picture [fit], clamped to the picture's edges. */
    fun canvasToPicture(x: Double, y: Double, fit: CanvasRect): NormalizedPoint =
        fit.normalize((x - panX) / zoom, (y - panY) / zoom)

    private fun clampedTo(zoom: Double, panX: Double, panY: Double, canvas: CanvasSize): CanvasViewport {
        val lowestX = canvas.width * (1 - zoom)
        val lowestY = canvas.height * (1 - zoom)
        return CanvasViewport(
            zoom = zoom,
            panX = panX.coerceIn(minOf(lowestX, 0.0), 0.0),
            panY = panY.coerceIn(minOf(lowestY, 0.0), 0.0),
        )
    }

    companion object {
        const val MIN_ZOOM = 1.0
        const val MAX_ZOOM = 4.0
    }
}
