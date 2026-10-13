package pl.dmq.peering.feature.agents

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
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.loadingFade
import pl.dmq.peering.ui.kit.hubCardSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/** Placeholder cards, shown after a short wait, while the computer has not yet listed its conversations. */
@Composable
internal fun HubLoadingRows(modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().loadingFade(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        repeat(3) { Placeholder() }
    }
}

@Composable
private fun Placeholder() {
    Row(
        Modifier.fillMaxWidth().hubCardSurface(peeringShapes.medium).padding(12.dp),
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
