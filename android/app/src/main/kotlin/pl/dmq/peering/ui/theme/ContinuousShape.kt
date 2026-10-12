package pl.dmq.peering.ui.theme

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * A rounded rectangle with the iPhone's continuous corners: the curve eases into the straight edge instead of meeting it
 * at a quarter circle. Corner geometry follows the usual 60 percent smoothing construction.
 */
class ContinuousShape(private val radius: Dp, private val smoothing: Float = 0.6f) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val r = with(density) { radius.toPx() }
        return Outline.Generic(continuousRectPath(size.width, size.height, r, smoothing))
    }
}

val PillShape = ContinuousShape(1000.dp, smoothing = 0f)

private fun continuousRectPath(width: Float, height: Float, requested: Float, requestedSmoothing: Float): Path {
    val budget = min(width, height) / 2f
    val r = min(requested, budget)
    if (r <= 0f) return Path().apply { addRect(androidx.compose.ui.geometry.Rect(0f, 0f, width, height)) }
    val smoothing = min(requestedSmoothing, budget / r - 1f).coerceAtLeast(0f)
    val p = min((1f + smoothing) * r, budget)
    val arcMeasure = 90f * (1f - smoothing)
    val arcSection = (sin(rad(arcMeasure / 2f)) * r * sqrt(2f))
    val alpha = (90f - arcMeasure) / 2f
    val p3p4 = r * tan(rad(alpha / 2f))
    val beta = 45f * smoothing
    val c = p3p4 * cos(rad(beta))
    val d = c * tan(rad(beta))
    val b = (p - arcSection - c - d) / 3f
    val a = 2f * b

    return Path().apply {
        moveTo(p, 0f)
        lineTo(width - p, 0f)
        corner(r, smoothing, a, b, c, d, arcSection, 0)
        lineTo(width, height - p)
        corner(r, smoothing, a, b, c, d, arcSection, 1)
        lineTo(p, height)
        corner(r, smoothing, a, b, c, d, arcSection, 2)
        lineTo(0f, p)
        corner(r, smoothing, a, b, c, d, arcSection, 3)
        close()
    }
}

/** One corner as relative segments, turned a quarter circle clockwise per [turns]. */
private fun Path.corner(r: Float, smoothing: Float, a: Float, b: Float, c: Float, d: Float, arc: Float, turns: Int) {
    fun x(vx: Float, vy: Float) = when (turns) { 0 -> vx; 1 -> -vy; 2 -> -vx; else -> vy }
    fun y(vx: Float, vy: Float) = when (turns) { 0 -> vy; 1 -> vx; 2 -> -vy; else -> -vx }
    relativeCubicTo(x(a, 0f), y(a, 0f), x(a + b, 0f), y(a + b, 0f), x(a + b + c, d), y(a + b + c, d))
    val sweep = rad(90f * (1f - smoothing))
    val start = rad(45f * smoothing)
    val k = 4f / 3f * tan(sweep / 4f) * r
    val end = start + sweep
    relativeCubicTo(
        x(k * cos(start), k * sin(start)), y(k * cos(start), k * sin(start)),
        x(arc - k * cos(end), arc - k * sin(end)), y(arc - k * cos(end), arc - k * sin(end)),
        x(arc, arc), y(arc, arc),
    )
    relativeCubicTo(x(d, c), y(d, c), x(d, b + c), y(d, b + c), x(d, a + b + c), y(d, a + b + c))
}

private fun rad(degrees: Float): Float = (degrees * PI / 180.0).toFloat()
