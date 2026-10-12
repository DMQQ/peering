package pl.dmq.peering.feature.remote

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PanelShape
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.sessionSurface

/**
 * The surface a panel opens on, over the picture and above the controls it belongs to: at most 520 wide and [maxHeight]
 * tall, bottom aligned by its parent. The surface opens and closes as one piece; switching panels only changes what is
 * inside it, and the surface follows the new height in the layout phase.
 */
@Composable
fun FloatingPanel(
    panel: SessionPanel?,
    maxHeight: Dp,
    modifier: Modifier = Modifier,
    content: @Composable (SessionPanel) -> Unit,
) {
    val memory = remember { PanelMemory() }
    val shown = memory.shown(panel)
    val rise = with(LocalDensity.current) { RISE.roundToPx() }
    AnimatedContent(
        targetState = panel != null,
        modifier = modifier,
        contentAlignment = Alignment.BottomCenter,
        transitionSpec = {
            val enter = tween<Float>(ENTER_MS, easing = FastOutSlowInEasing)
            val exit = tween<Float>(EXIT_MS, easing = FastOutSlowInEasing)
            val opening = fadeIn(enter) + slideInVertically(tween<IntOffset>(ENTER_MS, easing = FastOutSlowInEasing)) { it / 4 }
            val closing = fadeOut(exit) + slideOutVertically(tween<IntOffset>(EXIT_MS, easing = FastOutSlowInEasing)) { it / 4 }
            val spec = if (targetState) opening togetherWith fadeOut(exit) else fadeIn(enter) togetherWith closing
            spec.using(SizeTransform(clip = false) { _, _ -> snap() })
        },
        label = "panel",
    ) { open ->
        if (open && shown != null) {
            Box(
                Modifier
                    .padding(horizontal = 10.dp)
                    .widthIn(max = ChromeMetrics.panelMaxWidth)
                    .fillMaxWidth()
                    .heightIn(max = maxHeight)
                    .sessionSurface(PanelShape)
                    .blockTouches(),
            ) {
                AnimatedContent(
                    targetState = shown,
                    transitionSpec = {
                        val incoming = fadeIn(tween(SWITCH_IN_MS, easing = FastOutSlowInEasing)) +
                            slideInVertically(tween<IntOffset>(SWITCH_IN_MS, easing = FastOutSlowInEasing)) { rise }
                        val outgoing = fadeOut(tween(SWITCH_OUT_MS))
                        (incoming togetherWith outgoing).using(
                            SizeTransform(clip = true) { _, _ ->
                                spring(Spring.DampingRatioNoBouncy, Spring.StiffnessMediumLow, IntSize(1, 1))
                            },
                        )
                    },
                    label = "panel body",
                ) { which ->
                    Box(Modifier.fillMaxWidth()) { content(which) }
                }
            }
        }
    }
}

private val RISE = 8.dp
private const val ENTER_MS = 220
private const val EXIT_MS = 160
private const val SWITCH_IN_MS = 160
private const val SWITCH_OUT_MS = 90
