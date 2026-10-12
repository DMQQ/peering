package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import kotlin.math.PI
import kotlin.math.sin

/** [y] is a fraction of the field's height, measured to the chip's top edge. */
data class FloatingChip(val symbol: ImageVector, val title: String, val atEnd: Boolean, val y: Float)

/** Chips hung on the edges of the box they fill, each fading in and then drifting on its own phase. */
@Composable
fun FloatingChips(chips: List<FloatingChip>, modifier: Modifier = Modifier) {
    val drift = rememberInfiniteTransition(label = "drift").animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(tween(durationMillis = 6980, easing = LinearEasing), RepeatMode.Restart),
        label = "driftPhase",
    )
    BoxWithConstraints(modifier.fillMaxSize()) {
        chips.forEachIndexed { index, chip ->
            val arrived = remember(chip.title) { Animatable(0f) }
            LaunchedEffect(chip.title) {
                delay(50L + 120L + index * 90L)
                arrived.animateTo(1f, tween(durationMillis = 300, easing = FastOutSlowInEasing))
            }
            Row(
                modifier = Modifier
                    .align(if (chip.atEnd) Alignment.TopEnd else Alignment.TopStart)
                    .offset(y = maxHeight * chip.y)
                    .graphicsLayer {
                        val progress = arrived.value
                        alpha = progress.coerceIn(0f, 1f)
                        scaleX = 0.8f + 0.2f * progress
                        scaleY = 0.8f + 0.2f * progress
                        translationY = (1f - progress) * 14.dp.toPx() + sin(drift.value + index * 2f) * 4.dp.toPx()
                    }
                    .chipSurface(CircleShape)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(chip.symbol, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(6.dp))
                Text(chip.title, style = PeeringText.captionSemibold.copy(fontWeight = FontWeight.SemiBold), color = PeeringColors.ink, maxLines = 1, softWrap = false)
            }
        }
    }
}
