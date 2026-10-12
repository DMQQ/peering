package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush

private const val BASE_ALPHA = 0.78f
private const val PEAK_ALPHA = 0.9f
private const val BAND = 0.34f
private const val CROSSING_MILLIS = 1600
private const val CYCLE_MILLIS = 4200

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

/** The display headings' paint: white at 0.78 with a lighter band that crosses in 1.6 seconds every 4.2. Pass it as the text style's brush. */
@Composable
fun rememberSheen(active: Boolean = true): androidx.compose.ui.graphics.Brush {
    val still = remember { SheenBrush(-1f) }
    if (!active) return still
    val phase by rememberInfiniteTransition(label = "sheen").animateFloat(
        initialValue = -BAND / 2,
        targetValue = 1f + BAND / 2,
        animationSpec = infiniteRepeatable(
            animation = keyframes {
                durationMillis = CYCLE_MILLIS
                (-BAND / 2) at 0
                (1f + BAND / 2) at CROSSING_MILLIS using LinearEasing
                (1f + BAND / 2) at CYCLE_MILLIS
            },
            repeatMode = RepeatMode.Restart,
        ),
        label = "sheenPhase",
    )
    return SheenBrush(phase)
}
