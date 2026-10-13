package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize

/** A rectangle in canvas pixels. */
data class CanvasRect(val left: Double, val top: Double, val width: Double, val height: Double) {
    /** The point at ([x], [y]) inside this rectangle as a fraction of its size, clamped to the edges. */
    fun normalize(x: Double, y: Double): NormalizedPoint = NormalizedPoint(
        x = (x - left) / width,
        y = (y - top) / height,
    ).clamped()
}

/** The largest rectangle with the picture's shape that fits the canvas, centred. Null when any size is empty. */
fun aspectFitRect(picture: PixelSize, canvas: CanvasSize): CanvasRect? {
    if (picture.width <= 0 || picture.height <= 0 || canvas.width <= 0 || canvas.height <= 0) return null
    val scale = minOf(canvas.width / picture.width, canvas.height / picture.height)
    val width = picture.width * scale
    val height = picture.height * scale
    return CanvasRect(
        left = (canvas.width - width) / 2,
        top = (canvas.height - height) / 2,
        width = width,
        height = height,
    )
}
