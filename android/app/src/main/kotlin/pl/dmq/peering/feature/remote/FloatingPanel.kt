package pl.dmq.peering.feature.remote

import pl.dmq.peering.ui.kit.WidthClass
import pl.dmq.peering.ui.kit.rememberWidthClass
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.snap
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PanelShape
import pl.dmq.peering.ui.kit.Motion
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.rememberMotionDistances
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
    val maxWidth = if (rememberWidthClass() == WidthClass.Compact) ChromeMetrics.panelMaxWidth else ChromeMetrics.panelMaxWidthWide
    val shown = memory.shown(panel)
    val rise = rememberMotionDistances().risePx
    AnimatedContent(
        targetState = panel != null,
        modifier = modifier,
        contentAlignment = Alignment.BottomCenter,
        transitionSpec = {
            val spec = if (targetState) Motion.enterRising(rise) togetherWith ExitTransition.None else EnterTransition.None togetherWith Motion.leave
            spec.using(SizeTransform(clip = false) { _, _ -> snap() })
        },
        label = "panel",
    ) { open ->
        if (open && shown != null) {
            Box(
                Modifier
                    .padding(horizontal = 10.dp)
                    .widthIn(max = maxWidth)
                    .fillMaxWidth()
                    .heightIn(max = maxHeight)
                    .sessionSurface(PanelShape)
                    .blockTouches(),
            ) {
                AnimatedContent(
                    targetState = shown,
                    transitionSpec = {
                        (fadeIn(Motion.fast()) togetherWith fadeOut(Motion.fast()))
                            .using(SizeTransform(clip = true) { _, _ -> Motion.spring(IntSize(1, 1)) })
                    },
                    label = "panel body",
                ) { which ->
                    Box(Modifier.fillMaxWidth()) { content(which) }
                }
            }
        }
    }
}

