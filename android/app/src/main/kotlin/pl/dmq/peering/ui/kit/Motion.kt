package pl.dmq.peering.ui.kit

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp

/**
 * The app's whole motion vocabulary. Anything that moves takes its timing from here. Entrances fade and rise by [rise]
 * at most; exits are shorter than entrances; nothing scales in and nothing bounces.
 */
object Motion {
    const val FAST_MS = 120
    const val STANDARD_MS = 260
    const val EMPHASIZED_MS = 400
    const val EXIT_MS = 110

    /** Material 3 shared axis: the slide takes [AXIS_MS], the old page is gone after [EXIT_MS], the new one fades in over [AXIS_FADE_IN_MS] after that. */
    const val AXIS_MS = 380
    const val AXIS_FADE_IN_MS = 240

    /** How long a loading state waits before it shows, so a fast answer never flashes a skeleton. */
    const val LOADING_DELAY_MS = 150L

    val rise = 8.dp
    val axisDistance = 30.dp

    val emphasizedDecelerate = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)

    /** A long, soft landing for slides: most of the travel happens early and the last stretch eases in gently. */
    val glide = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

    /** Press feedback, small reveals and crossfades. */
    fun <T> fast(): FiniteAnimationSpec<T> = tween(FAST_MS, easing = FastOutSlowInEasing)

    /** The default for anything that enters, moves or changes colour. */
    fun <T> standard(): FiniteAnimationSpec<T> = tween(STANDARD_MS, easing = FastOutSlowInEasing)

    /** Large surfaces arriving. */
    fun <T> emphasized(): FiniteAnimationSpec<T> = tween(EMPHASIZED_MS, easing = emphasizedDecelerate)

    /** Anything leaving: shorter than its entrance, accelerating out. */
    fun <T> exit(): FiniteAnimationSpec<T> = tween(EXIT_MS, easing = FastOutLinearInEasing)

    /** Resizes and expansions. Critically damped, so it settles without bouncing. */
    fun <T> spring(visibilityThreshold: T? = null): FiniteAnimationSpec<T> =
        spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMedium, visibilityThreshold = visibilityThreshold)

    val enter: EnterTransition = fadeIn(standard())
    val leave: ExitTransition = fadeOut(exit())

    /** Fade in while rising [risePx] from below. */
    fun enterRising(risePx: Int): EnterTransition =
        fadeIn(standard()) + slideInVertically(tween(EMPHASIZED_MS, easing = glide)) { risePx }
}

/** Pixel values the transitions need, resolved once per density. */
class MotionDistances(val axisPx: Int, val risePx: Int)

@Composable
fun rememberMotionDistances(): MotionDistances {
    val density = LocalDensity.current
    return remember(density) {
        MotionDistances(with(density) { Motion.axisDistance.roundToPx() }, with(density) { Motion.rise.roundToPx() })
    }
}

private val snapSize = SizeTransform(clip = false) { _, _ -> snap() }

private fun transform(enter: EnterTransition, exit: ExitTransition, zIndex: Float = 0f) =
    ContentTransform(enter, exit, zIndex, snapSize)

fun motionTransition(kind: MotionKind, distances: MotionDistances): ContentTransform = when (kind) {
    MotionKind.FORWARD -> sharedAxisX(1, distances.axisPx)
    MotionKind.BACKWARD -> sharedAxisX(-1, distances.axisPx)
    MotionKind.CROSSFADE -> transform(fadeIn(Motion.fast()), fadeOut(Motion.fast()))
    MotionKind.MODAL_UP -> transform(Motion.enterRising(distances.risePx), ExitTransition.None, zIndex = 1f)
    MotionKind.MODAL_DOWN -> transform(EnterTransition.None, Motion.leave, zIndex = 1f)
}

/** Material 3 shared axis X: both pages slide 30 dp the same way, the old one fades out quickly and the new one fades in after it. */
private fun sharedAxisX(sign: Int, axisPx: Int): ContentTransform {
    val slide = tween<IntOffset>(Motion.AXIS_MS, easing = Motion.glide)
    val enter = slideInHorizontally(slide) { sign * axisPx } +
        fadeIn(tween(Motion.AXIS_FADE_IN_MS, delayMillis = Motion.EXIT_MS, easing = FastOutSlowInEasing))
    val exit = slideOutHorizontally(slide) { -sign * axisPx } + fadeOut(tween(Motion.EXIT_MS, easing = FastOutLinearInEasing))
    return transform(enter, exit)
}

/** Content that moves deeper or back by [depth] between states: shared axis forward and back, a crossfade between peers. */
@Composable
fun <T> DepthTransition(
    state: T,
    depth: (T) -> Int,
    modifier: Modifier = Modifier,
    label: String = "depth",
    content: @Composable (T) -> Unit,
) {
    val distances = rememberMotionDistances()
    AnimatedContent(
        targetState = state,
        modifier = modifier,
        transitionSpec = { motionTransition(depthMotion(depth(initialState), depth(targetState)), distances) },
        label = label,
    ) { content(it) }
}
