package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush
import kotlinx.coroutines.delay

private const val BASE_ALPHA = 0.78f
private const val PEAK_ALPHA = 0.9f
private const val BAND = 0.34f
private const val CROSSING_MILLIS = 1600
private const val START_DELAY_MILLIS = 500L

private class SheenBrush(private val phase: Float) : ShaderBrush() {
    override fun createShader(size: Size): Shader {
        val base = Color.White.copy(alpha = BASE_ALPHA)
        val peak = Color.White.copy(alpha = PEAK_ALPHA)
        val centre = phase
        val stops = listOf(0f, (centre - BAND / 2).coerceIn(0f, 1f), centre.coerceIn(0f, 1f), (centre + BAND / 2).coerceIn(0f, 1f), 1f)
        return LinearGradientShader(
            from = Offset.Zero,
            to = Offset(size.width.coerceAtLeast(1f), 0f),
            colors = listOf(base, base, peak, base, base),
            colorStops = stops,
        )
    }
}

/**
 * The display headings' paint: white at 0.78 with a lighter band that crosses once, 1.6 seconds after the heading
 * appears, and then rests. It does not repeat: a looping brush is a new brush every frame, which keeps the screen
 * recomposing and redrawing for as long as it is shown. Pass it as the text style's brush.
 */
@Composable
fun rememberSheen(active: Boolean = true): Brush {
    val crossing = remember { Animatable(-BAND / 2) }
    LaunchedEffect(active) {
        if (active && crossing.value < 0f) {
            delay(START_DELAY_MILLIS)
            crossing.animateTo(1f + BAND / 2, tween(CROSSING_MILLIS, easing = LinearEasing))
        }
    }
    return remember(crossing.value) { SheenBrush(if (crossing.value < 0f) -1f else crossing.value) }
}
