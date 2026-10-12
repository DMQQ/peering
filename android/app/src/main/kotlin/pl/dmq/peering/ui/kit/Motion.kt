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
private const val PUSH_IN_MS = 340
private const val PUSH_OUT_MS = 280
private const val STACK_MS = 340
private const val STACK_PARALLAX = 4
private const val CROSSFADE_MS = 120
private val axisDistance = 30.dp

/** Fade through for peers such as the root tabs: the old content fades out, then the new fades in. No scale, no movement. */
val FadeThroughEnter: EnterTransition =
    fadeIn(tween(TAB_IN_MS, delayMillis = FADE_OUT_MS, easing = FastOutSlowInEasing))

val FadeThroughExit: ExitTransition = fadeOut(tween(FADE_OUT_MS, easing = FastOutLinearInEasing))

fun motionTransition(kind: MotionKind, axisDistancePx: Int): ContentTransform = when (kind) {
    MotionKind.FADE_THROUGH -> FadeThroughEnter togetherWith FadeThroughExit
    MotionKind.FORWARD -> stackPush(1)
    MotionKind.BACKWARD -> stackPush(-1)
    MotionKind.CROSSFADE -> fadeIn(tween(CROSSFADE_MS)) togetherWith fadeOut(tween(CROSSFADE_MS))
    MotionKind.FADE -> fadeIn(tween(FADE_IN_MS, easing = FastOutSlowInEasing)) togetherWith fadeOut(tween(CROSSFADE_MS))
    MotionKind.MODAL_UP -> (
        fadeIn(tween(MODAL_IN_MS, easing = FastOutSlowInEasing)) +
            slideInVertically(tween(MODAL_IN_MS, easing = FastOutSlowInEasing)) { it }
        ).togetherWith(ExitTransition.None).apply { targetContentZIndex = 1f }
    MotionKind.PUSH_IN -> slideInHorizontally(tween(PUSH_IN_MS, easing = FastOutSlowInEasing)) { it }
        .togetherWith(ExitTransition.None).apply { targetContentZIndex = 1f }
    MotionKind.PUSH_OUT -> EnterTransition.None togetherWith slideOutHorizontally(tween(PUSH_OUT_MS, easing = FastOutLinearInEasing)) { it }
    MotionKind.MODAL_DOWN -> EnterTransition.None togetherWith (
        fadeOut(tween(MODAL_OUT_MS, easing = FastOutLinearInEasing)) +
            slideOutVertically(tween(MODAL_OUT_MS, easing = FastOutLinearInEasing)) { it }
        )
}

/** The native stack push: the new screen covers the old one from the right, and the old one drifts a quarter of the way left and fades. Going back is the same in reverse. */
private fun stackPush(sign: Int): ContentTransform {
    val slide = tween<IntOffset>(STACK_MS, easing = FastOutSlowInEasing)
    val fade = tween<Float>(STACK_MS, easing = FastOutSlowInEasing)
    return if (sign > 0) {
        (slideInHorizontally(slide) { it } togetherWith (slideOutHorizontally(slide) { -it / STACK_PARALLAX } + fadeOut(fade)))
            .apply { targetContentZIndex = 1f }
    } else {
        ((slideInHorizontally(slide) { -it / STACK_PARALLAX } + fadeIn(fade)) togetherWith slideOutHorizontally(slide) { it })
            .apply { targetContentZIndex = -1f }
    }
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
