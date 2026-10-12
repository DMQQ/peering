package pl.dmq.peering.feature.remote

/** What the canvas draws: the zoom and pan, and the fitted picture rectangle in unzoomed canvas pixels, if known. */
data class CanvasUiState(val viewport: CanvasViewport, val picture: CanvasRect?) {
    companion object {
        val INITIAL = CanvasUiState(viewport = CanvasViewport(), picture = null)
    }
}
