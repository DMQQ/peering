package pl.dmq.peering.feature.remote

import androidx.compose.animation.AnimatedContent
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
        transitionSpec = { (fadeIn() + slideInVertically { it / 6 }) togetherWith (fadeOut() + slideOutVertically { it / 6 }) },
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
