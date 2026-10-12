package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** The status line over the top of the picture: latency, the path, the picture state and any relay notice. */
@Composable
fun SessionOverlay(state: SessionOverlayState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            state.latencyMs?.let {
                Text(
                    text = stringResource(R.string.overlay_latency, it),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.muted,
                )
            }
            state.path?.let { path -> PathBadge(path) }
            state.picture.labelRes()?.let {
                Text(
                    text = stringResource(it),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.muted,
                )
            }
        }
        if (state.picture == PictureState.STALLED || state.picture == PictureState.FAILED) {
            TextButton(onClick = onRetry) { Text(stringResource(R.string.overlay_picture_retry)) }
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

private fun PictureState.labelRes(): Int? = when (this) {
    PictureState.WAITING -> R.string.overlay_picture_waiting
    PictureState.PAUSED -> R.string.overlay_picture_paused
    PictureState.STALLED -> R.string.overlay_picture_stalled
    PictureState.FAILED -> R.string.overlay_picture_failed
    PictureState.LIVE -> null
}
