package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout

/** One tile of the mosaic as the overlay draws it: where, what it is called, and whether it is being carried or dropped on. */
data class OverlayTile(
    val index: Int,
    val rect: CanvasRect,
    val title: String?,
    val held: Boolean,
    val target: Boolean,
    val showsTitle: Boolean,
    val showsClose: Boolean,
)

/** Smallest tile widths, in dp, that carry a name and a close button: on a small tile either would cover the window. */
private const val TITLE_MINIMUM_DP = 120.0
private const val CLOSE_MINIMUM_DP = 140.0

/**
 * The tiles of [layout] on the canvas. A lifted tile is drawn under the finger at [drag]'s point, and carries no close
 * button while anything is lifted, so a drop cannot land on one.
 */
fun overlayTiles(
    layout: MosaicLayout,
    viewport: CanvasViewport,
    fit: CanvasRect,
    drag: MosaicDrag?,
    density: Double,
    titleOf: (CaptureSource) -> String?,
): List<OverlayTile> = layout.tiles.indices.mapNotNull { index ->
    val rest = MosaicHit.tileRect(layout, viewport, fit, index) ?: return@mapNotNull null
    val held = drag?.held == index
    val drawn = if (held && drag != null) rest.copy(left = drag.x - rest.width / 2, top = drag.y - rest.height / 2) else rest
    OverlayTile(
        index = index,
        rect = drawn,
        title = titleOf(layout.tiles[index].source),
        held = held,
        target = drag != null && drag.target == index && drag.held != index,
        showsTitle = rest.width / density > TITLE_MINIMUM_DP,
        showsClose = drag == null && rest.width / density > CLOSE_MINIMUM_DP,
    )
}
