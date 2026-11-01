package pl.dmq.peering.feature.sessionmode

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.sin
import pl.dmq.peering.ui.theme.PeeringColors

/** Where a tap landed, in pad pixels. Each tap gets a new [serial], so two taps on one spot each ring out. */
data class DotTap(val point: Offset, val serial: Int)

private class DotRipple(val point: Offset, val startNanos: Long)

/** The pad's texture: small dots under a slow drifting swell, which bulge and brighten around the finger and ring out from a tap. */
@Composable
fun DotField(touch: Offset?, tap: DotTap?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val still = remember(context) { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    var now by remember { mutableLongStateOf(0L) }
    LaunchedEffect(still) {
        while (true) withFrameNanos { now = if (still) 0L else it }
    }
    val ripple = remember(tap) { tap?.takeUnless { still }?.let { DotRipple(it.point, Snapshot.withoutReadObservation { now }) } }
    Canvas(modifier) { drawDots(touch, ripple, now) }
}

private fun DrawScope.drawDots(touch: Offset?, ripple: DotRipple?, now: Long) {
    val spacing = 14.dp.toPx()
    val columns = (size.width / spacing).toInt()
    val rows = (size.height / spacing).toInt()
    val insetX = (size.width - columns * spacing) / 2 + spacing / 2
    val insetY = (size.height - rows * spacing) / 2 + spacing / 2
    val time = now / 1e9
    val scale = 1.dp.toPx()
    for (row in 0 until rows) {
        for (column in 0 until columns) {
            val center = Offset(insetX + column * spacing, insetY + row * spacing)
            val swell = 0.5 + 0.5 * sin(time * 1.1 - (center.x + center.y * 0.6) / scale * 0.018)
            val lift = max(closeness(center, touch, 90.dp.toPx()), rippleLift(center, ripple, now, scale))
            val radius = (1.1f + swell.toFloat() * 0.35f + lift * 2.2f) * scale
            val alpha = (0.17 + swell * 0.1 + lift * 0.58).toFloat().coerceIn(0f, 1f)
            drawCircle(PeeringColors.ink.copy(alpha = alpha), radius, center)
        }
    }
}

private fun closeness(point: Offset, touch: Offset?, reach: Float): Float {
    touch ?: return 0f
    return falloff(hypot(point.x - touch.x, point.y - touch.y), reach)
}

private fun rippleLift(point: Offset, ripple: DotRipple?, now: Long, scale: Float): Float {
    ripple ?: return 0f
    val age = (now - ripple.startNanos) / 1e9f
    if (age < 0f || age >= RIPPLE_SECONDS) return 0f
    val radius = age * RIPPLE_SPEED_DP * scale
    val distance = abs(hypot(point.x - ripple.point.x, point.y - ripple.point.y) - radius)
    return falloff(distance, 22f * scale) * (1 - age / RIPPLE_SECONDS) * 0.7f
}

private fun falloff(distance: Float, width: Float): Float {
    if (distance >= width) return 0f
    val t = 1 - distance / width
    return t * t * (3 - 2 * t)
}

private const val RIPPLE_SECONDS = 0.7f
private const val RIPPLE_SPEED_DP = 420f
