package pl.dmq.peering.feature.remote

/** A mosaic tile lifted by a long press: [held] follows the finger at [x], [y] and [target] is the place it would drop into. */
data class MosaicDrag(val held: Int, val target: Int, val x: Double, val y: Double)

/** What the canvas draws: the zoom and pan, and the fitted picture rectangle in unzoomed canvas pixels, if known. */
data class CanvasUiState(val viewport: CanvasViewport, val picture: CanvasRect?, val drag: MosaicDrag? = null) {
    companion object {
        val INITIAL = CanvasUiState(viewport = CanvasViewport(), picture = null)
    }
}
