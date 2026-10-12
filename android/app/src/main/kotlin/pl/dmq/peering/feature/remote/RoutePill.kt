package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape

/** A 32 dp pill with a status dot, the route (Direct, Relay or LAN) and the latency, always on one line. */
@Composable
fun RoutePill(state: SessionOverlayState, modifier: Modifier = Modifier) {
    val route = state.path?.let { stringResource(it.labelRes()) }
    val latency = state.latencyMs?.let { stringResource(R.string.overlay_latency, it) }
    val text = listOfNotNull(route, latency).joinToString(" · ")
    Surface(modifier = modifier.height(32.dp), shape = PillShape, color = PeeringColors.containerHighest) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(dotColor(RouteHealth.of(state))))
            if (text.isNotEmpty()) {
                Text(
                    text = text,
                    style = MaterialTheme.typography.labelLarge,
                    color = PeeringColors.ink,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

private fun dotColor(health: RouteHealth): Color = when (health) {
    RouteHealth.GOOD -> PeeringColors.added
    RouteHealth.DEGRADED -> PeeringColors.caution
    RouteHealth.BROKEN -> PeeringColors.danger
    RouteHealth.UNKNOWN -> PeeringColors.muted
}
