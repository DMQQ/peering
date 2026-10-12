package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * The status pill over the top of the picture: the computer's name and a dot for the link, the route, the latency
 * and the picture state, an assist chip that fits the picture while zoomed, and the disconnect button. A relay
 * notice sits under the pill.
 */
@Composable
fun SessionOverlay(
    state: SessionOverlayState,
    zoomPercent: Int?,
    onFit: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Surface(
            modifier = Modifier.heightIn(min = 48.dp),
            shape = peeringShapes.extraLarge,
            color = PeeringColors.containerHigh,
            shadowElevation = 6.dp,
        ) {
            Row(
                modifier = Modifier.padding(start = 16.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                StatusDot(statusColor(state))
                Column(modifier = Modifier.weight(1f, fill = false).padding(vertical = 6.dp)) {
                    Text(
                        text = state.hostName ?: stringResource(R.string.remote_computer_fallback),
                        style = MaterialTheme.typography.titleSmall,
                        color = PeeringColors.ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = detailLine(state),
                        style = MaterialTheme.typography.labelMedium,
                        color = PeeringColors.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                zoomPercent?.let {
                    AssistChip(
                        onClick = onFit,
                        label = { Text(stringResource(R.string.remote_zoom_percent, it), maxLines = 1) },
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

@Composable
private fun detailLine(state: SessionOverlayState): String = listOfNotNull(
    state.path?.let { stringResource(it.labelRes()) },
    state.latencyMs?.let { stringResource(R.string.overlay_latency, it) },
    stringResource(state.pictureLabel()),
).joinToString(" \u00B7 ")

@Composable
private fun StatusDot(color: Color) {
    Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
}

private fun statusColor(state: SessionOverlayState): Color = when {
    state.reconnecting || state.picture == PictureState.STALLED || state.picture == PictureState.PAUSED -> PeeringColors.caution
    state.picture == PictureState.FAILED -> PeeringColors.danger
    state.picture == PictureState.LIVE -> PeeringColors.added
    else -> PeeringColors.muted
}

private fun SessionOverlayState.pictureLabel(): Int = when (picture) {
    PictureState.WAITING -> R.string.overlay_picture_waiting
    PictureState.LIVE -> R.string.overlay_picture_live
    PictureState.PAUSED -> R.string.overlay_picture_paused
    PictureState.STALLED -> R.string.overlay_picture_stalled
    PictureState.FAILED -> R.string.overlay_picture_failed
}
