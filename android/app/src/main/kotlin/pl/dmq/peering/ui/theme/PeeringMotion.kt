package pl.dmq.peering.ui.theme

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/** DESIGN.md's motion tokens, as springs. `arrive` is the only critically damped one: an entrance must not give. */
object PeeringMotion {
    val arrive: FiniteAnimationSpec<Float> = spring(dampingRatio = 1f, stiffness = 146f)
    val settle: FiniteAnimationSpec<Float> = spring(dampingRatio = 0.84f, stiffness = 340f)
    val tap: FiniteAnimationSpec<Float> = tween(durationMillis = 180)
    const val PRESSED_SCALE = 0.98f
}

private val risePixels = 14.dp

/** Fades and rises into place after [delayMillis], once per [key]. */
fun Modifier.arrive(delayMillis: Int = 0, key: Any = Unit): Modifier = composed {
    val progress = remember(key) { Animatable(0f) }
    val rise = with(LocalDensity.current) { risePixels.toPx() }
    LaunchedEffect(key) {
        delay(delayMillis.toLong())
        progress.animateTo(1f, PeeringMotion.arrive)
    }
    graphicsLayer {
        alpha = progress.value
        translationY = rise * (1f - progress.value)
    }
}
