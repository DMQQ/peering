package pl.dmq.peering.feature.remote

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * The surface a panel opens on, over the picture and above the controls it belongs to: at most 520 wide and [maxHeight]
 * tall, bottom aligned by its parent. One panel at a time, and one replaces another in place.
 */
@Composable
fun FloatingPanel(
    panel: SessionPanel?,
    maxHeight: Dp,
    modifier: Modifier = Modifier,
    content: @Composable (SessionPanel) -> Unit,
) {
    AnimatedContent(
        targetState = panel,
        modifier = modifier,
        transitionSpec = {
            val enter = tween<Float>(ENTER_MS, easing = FastOutSlowInEasing)
            val exit = tween<Float>(EXIT_MS, easing = FastOutSlowInEasing)
            val rise = tween<IntOffset>(ENTER_MS, easing = FastOutSlowInEasing)
            val fall = tween<IntOffset>(EXIT_MS, easing = FastOutSlowInEasing)
            val move = panelTransition(initialState, targetState)
            val entering = if (move == PanelTransition.RISE) fadeIn(enter) + slideInVertically(rise) { it / 4 } else fadeIn(enter)
            val leaving = if (move == PanelTransition.FALL) fadeOut(exit) + slideOutVertically(fall) { it / 4 } else fadeOut(exit)
            (entering togetherWith leaving).using(SizeTransform(clip = false) { _, _ -> snap() })
        },
        label = "panel",
    ) { shown ->
        if (shown != null) {
            Box(
                Modifier
                    .padding(horizontal = 10.dp)
                    .widthIn(max = ChromeMetrics.panelMaxWidth)
                    .fillMaxWidth()
                    .heightIn(max = maxHeight)
                    .sessionSurface(peeringShapes.medium)
                    .blockTouches(),
            ) { content(shown) }
        }
    }
}

private const val ENTER_MS = 220
private const val EXIT_MS = 160
