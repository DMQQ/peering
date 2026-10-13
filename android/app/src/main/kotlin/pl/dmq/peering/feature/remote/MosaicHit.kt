package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.NormalizedPoint

/** Which tile of a mosaic a touch on the canvas lands on, through the letterbox and the current zoom and pan. */
object MosaicHit {
    /** The tile index under canvas pixel ([x], [y]), or null for the bars beside the picture or a gap between tiles. */
    fun tileAt(layout: MosaicLayout, viewport: CanvasViewport, fit: CanvasRect, x: Double, y: Double): Int? {
        val shown = viewport.displayed(fit)
        if (x < shown.left || y < shown.top || x >= shown.left + shown.width || y >= shown.top + shown.height) return null
        return layout.tileIndexAt(NormalizedPoint((x - shown.left) / shown.width, (y - shown.top) / shown.height))
    }

    /** Where tile [index] is drawn on the canvas, in canvas pixels, or null for an index the layout does not have. */
    fun tileRect(layout: MosaicLayout, viewport: CanvasViewport, fit: CanvasRect, index: Int): CanvasRect? {
        val tile = layout.tiles.getOrNull(index) ?: return null
        val shown = viewport.displayed(fit)
        return CanvasRect(
            left = shown.left + tile.rect.x * shown.width,
            top = shown.top + tile.rect.y * shown.height,
            width = tile.rect.width * shown.width,
            height = tile.rect.height * shown.height,
        )
    }
}
