package pl.dmq.peering.ui.kit

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp

private const val FADE_IN_MS = 210
private const val FADE_OUT_MS = 90
private const val TAB_IN_MS = 150
private const val AXIS_MS = 300
private const val MODAL_IN_MS = 280
private const val MODAL_OUT_MS = 200
private const val CROSSFADE_MS = 120
private val axisDistance = 30.dp

/** Fade through for peers such as the root tabs: the old content fades out, then the new fades in. No scale, no movement. */
val FadeThroughEnter: EnterTransition =
    fadeIn(tween(TAB_IN_MS, delayMillis = FADE_OUT_MS, easing = FastOutSlowInEasing))

val FadeThroughExit: ExitTransition = fadeOut(tween(FADE_OUT_MS, easing = FastOutLinearInEasing))

fun motionTransition(kind: MotionKind, axisDistancePx: Int): ContentTransform = when (kind) {
    MotionKind.FADE_THROUGH -> FadeThroughEnter togetherWith FadeThroughExit
    MotionKind.FORWARD -> sharedAxisX(1, axisDistancePx)
    MotionKind.BACKWARD -> sharedAxisX(-1, axisDistancePx)
    MotionKind.CROSSFADE -> fadeIn(tween(CROSSFADE_MS)) togetherWith fadeOut(tween(CROSSFADE_MS))
    MotionKind.FADE -> fadeIn(tween(FADE_IN_MS, easing = FastOutSlowInEasing)) togetherWith fadeOut(tween(CROSSFADE_MS))
    MotionKind.MODAL_UP -> (
        fadeIn(tween(MODAL_IN_MS, easing = FastOutSlowInEasing)) +
            slideInVertically(tween(MODAL_IN_MS, easing = FastOutSlowInEasing)) { it }
        ).togetherWith(ExitTransition.None).apply { targetContentZIndex = 1f }
    MotionKind.MODAL_DOWN -> EnterTransition.None togetherWith (
        fadeOut(tween(MODAL_OUT_MS, easing = FastOutLinearInEasing)) +
            slideOutVertically(tween(MODAL_OUT_MS, easing = FastOutLinearInEasing)) { it }
        )
}

private fun sharedAxisX(sign: Int, distancePx: Int): ContentTransform {
    val slide = tween<IntOffset>(AXIS_MS, easing = FastOutSlowInEasing)
    return (
        fadeIn(tween(FADE_IN_MS, delayMillis = FADE_OUT_MS, easing = FastOutSlowInEasing)) +
            slideInHorizontally(slide) { sign * distancePx }
        ) togetherWith (
        fadeOut(tween(FADE_OUT_MS, easing = FastOutLinearInEasing)) +
            slideOutHorizontally(slide) { -sign * distancePx }
        )
}

@Composable
fun rememberAxisDistancePx(): Int = with(LocalDensity.current) { axisDistance.roundToPx() }

/** Content that moves deeper or back by [depth] between states: shared axis forward and back, a crossfade between peers. */
@Composable
fun <T> DepthTransition(
    state: T,
    depth: (T) -> Int,
    modifier: Modifier = Modifier,
    label: String = "depth",
    content: @Composable (T) -> Unit,
) {
    val distance = rememberAxisDistancePx()
    AnimatedContent(
        targetState = state,
        modifier = modifier,
        transitionSpec = { motionTransition(depthMotion(depth(initialState), depth(targetState)), distance) },
        label = label,
    ) { content(it) }
}
