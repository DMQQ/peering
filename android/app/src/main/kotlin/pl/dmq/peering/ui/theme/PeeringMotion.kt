package pl.dmq.peering.ui.theme

import androidx.compose.ui.unit.IntOffset
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import kotlinx.coroutines.delay

/** DESIGN.md's motion tokens, as springs. `arrive` is the only critically damped one: an entrance must not give. */
object PeeringMotion {
    val arrive: FiniteAnimationSpec<Float> = tween(durationMillis = 300, easing = FastOutSlowInEasing)
    val settle: FiniteAnimationSpec<Float> = tween(durationMillis = 250, easing = FastOutSlowInEasing)
    val tap: FiniteAnimationSpec<Float> = tween(durationMillis = 180)
    val sharedAxis: FiniteAnimationSpec<IntOffset> = tween(durationMillis = 300, easing = FastOutSlowInEasing)
    const val PRESSED_SCALE = 0.98f
}

private val played = mutableSetOf<String>()

/** Fades in after [delayMillis], once per [key]. A [once] name plays only the first time in the process, so a revisited tab does not replay. */
fun Modifier.arrive(delayMillis: Int = 0, key: Any = Unit, once: String? = null): Modifier = composed {
    val progress = remember(key) { Animatable(if (once != null && once in played) 1f else 0f) }
    LaunchedEffect(key) {
        if (progress.value < 1f) {
            delay(delayMillis.toLong())
            progress.animateTo(1f, PeeringMotion.arrive)
        }
        if (once != null) played += once
    }
    graphicsLayer { alpha = progress.value }
}
