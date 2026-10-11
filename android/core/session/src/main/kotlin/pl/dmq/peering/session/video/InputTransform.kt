package pl.dmq.peering.session.video

import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize

/**
 * Maps a tap on the phone's picture to the captured source's own space. The picture is fitted into the view without
 * cropping, so it starts at ([originX], [originY]) and is [scale] view points for each source pixel.
 */
data class InputTransform(
    val originX: Double,
    val originY: Double,
    val scale: Double,
    val pixelSize: PixelSize,
) {
    /** Clamped: a gesture can overshoot the picture, and that must not push the cursor off the source. */
    fun normalizedPoint(viewX: Double, viewY: Double): NormalizedPoint = NormalizedPoint(
        x = (viewX - originX) / (pixelSize.width * scale),
        y = (viewY - originY) / (pixelSize.height * scale),
    ).clamped()

    companion object {
        /** Null when either size is empty, since there is no picture to map into. */
        fun fitted(pixelSize: PixelSize, viewWidth: Double, viewHeight: Double): InputTransform? {
            if (pixelSize.width <= 0 || pixelSize.height <= 0 || viewWidth <= 0 || viewHeight <= 0) return null
            val scale = minOf(viewWidth / pixelSize.width, viewHeight / pixelSize.height)
            return InputTransform(
                originX = (viewWidth - pixelSize.width * scale) / 2,
                originY = (viewHeight - pixelSize.height * scale) / 2,
                scale = scale,
                pixelSize = pixelSize,
            )
        }
    }
}
