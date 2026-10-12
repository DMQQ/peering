package pl.dmq.peering.ui.theme

import androidx.compose.animation.ContentTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.ui.unit.IntOffset
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
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
    val arrive: FiniteAnimationSpec<Float> = tween(durationMillis = 300, easing = FastOutSlowInEasing)
    val settle: FiniteAnimationSpec<Float> = tween(durationMillis = 250, easing = FastOutSlowInEasing)
    val tap: FiniteAnimationSpec<Float> = tween(durationMillis = 180)
    val sharedAxis: FiniteAnimationSpec<IntOffset> = tween(durationMillis = 300, easing = FastOutSlowInEasing)
    val fadeThroughIn: FiniteAnimationSpec<Float> = tween(durationMillis = 210, delayMillis = 90, easing = FastOutSlowInEasing)
    val fadeThroughOut: FiniteAnimationSpec<Float> = tween(durationMillis = 90, easing = FastOutLinearInEasing)
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

/** Material's fade through between two peers: the old content fades out, then the new fades and scales in. */
fun fadeThrough(): ContentTransform =
    (fadeIn(PeeringMotion.fadeThroughIn) + scaleIn(PeeringMotion.fadeThroughIn, initialScale = 0.92f)) togetherWith
        fadeOut(PeeringMotion.fadeThroughOut)
