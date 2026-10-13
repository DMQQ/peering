package pl.dmq.peering.feature.remote

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.session.video.MosaicEdit
import pl.dmq.peering.wire.PixelSize

/** The names and close buttons over a mosaic, and the edit a dropped tile makes. Nothing while a single source is up. */
@Composable
internal fun MosaicChrome(
    state: RemoteUiState,
    canvasState: CanvasUiState,
    canvas: RemoteCanvasPresenter,
    sources: SourcesPresenter,
    modifier: Modifier = Modifier,
) {
    val metrics = LocalContext.current.resources.displayMetrics
    val viewport = PixelSize(metrics.widthPixels.toDouble(), metrics.heightPixels.toDouble())
    val current by rememberUpdatedState(state)
    SideEffect {
        canvas.onTileMoved = { from, to ->
            current.mosaic?.let { sources.edit(it, MosaicEdit.Move(from, to), viewport, current.catalog) }
        }
    }
    val layout = state.mosaic ?: return
    val fit = canvasState.picture ?: return
    val known = state.catalog?.let { it.displays + it.applications + it.windows }.orEmpty()
    val tiles = overlayTiles(layout, canvasState.viewport, fit, canvasState.drag, metrics.density.toDouble()) { source ->
        known.firstOrNull { it.source == source }?.title
    }
    MosaicOverlay(tiles, onRemove = { index -> sources.edit(layout, MosaicEdit.Remove(index), viewport, state.catalog) }, modifier = modifier)
}
