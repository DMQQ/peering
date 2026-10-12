package pl.dmq.peering.feature.agents

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/** Placeholder cards that pulse while the computer has not yet listed its conversations. */
@Composable
internal fun HubLoadingRows(modifier: Modifier = Modifier) {
    val pulse = rememberInfiniteTransition(label = "hubLoading").animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
        label = "hubLoadingAlpha",
    )
    Column(modifier.fillMaxWidth().graphicsLayer { alpha = pulse.value }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        repeat(3) { Placeholder() }
    }
}

@Composable
private fun Placeholder() {
    Row(
        Modifier.fillMaxWidth().sessionSurface(peeringShapes.medium).padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Bar(Modifier.size(42.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Bar(Modifier.fillMaxWidth(0.6f).height(12.dp))
            Bar(Modifier.fillMaxWidth(0.35f).height(10.dp))
        }
    }
}

@Composable
private fun Bar(modifier: Modifier) {
    Box(modifier.clip(PillShape).background(PeeringColors.containerHighest))
}
