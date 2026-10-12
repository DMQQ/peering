package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * A slim top app bar over the picture: the computer's name, the route pill, a chip that fits the picture while it is
 * zoomed, and the disconnect button. A relay notice sits under the bar.
 */
@Composable
fun SessionTopBar(
    state: SessionOverlayState,
    zoomPercent: Int?,
    onFit: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            shape = peeringShapes.large,
            color = PeeringColors.containerHigh,
            shadowElevation = 6.dp,
        ) {
            Row(
                modifier = Modifier.padding(start = 20.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = state.hostName ?: stringResource(R.string.remote_computer_fallback),
                    style = MaterialTheme.typography.titleMedium,
                    color = PeeringColors.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                RoutePill(state)
                zoomPercent?.let {
                    AssistChip(
                        onClick = onFit,
                        label = { Text(stringResource(R.string.remote_zoom_percent, it), maxLines = 1, softWrap = false) },
                        shape = PillShape,
                    )
                }
                IconButton(onClick = onDisconnect) {
                    Icon(
                        imageVector = AppIcons.power,
                        contentDescription = stringResource(R.string.remote_disconnect_description),
                        tint = PeeringColors.danger,
                    )
                }
            }
        }
        state.quota?.let { notice ->
            val text = when (notice) {
                is QuotaNotice.Low -> stringResource(R.string.overlay_quota_low, notice.minutesLeft)
                QuotaNotice.Exhausted -> stringResource(R.string.overlay_quota_exhausted)
            }
            Text(
                text = text,
                style = MaterialTheme.typography.bodySmall,
                color = if (notice is QuotaNotice.Exhausted) PeeringColors.danger else PeeringColors.caution,
            )
        }
    }
}
