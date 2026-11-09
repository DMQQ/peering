package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * What the middle of the canvas says while there is no live picture. While the first frame is still on its way it is a
 * quiet wait: a small spinner and the computer's name on the black, no message and no card. Anything else is a calm
 * message, with Retry when asking again helps.
 */
@Composable
fun PictureStatus(picture: PictureState, hostName: String?, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    if (picture == PictureState.WAITING) return PicturePlaceholder(hostName, modifier)
    val message = when (picture) {
        PictureState.STALLED -> R.string.remote_no_picture_yet
        PictureState.FAILED -> R.string.overlay_picture_failed
        PictureState.PAUSED -> R.string.overlay_picture_paused
        PictureState.WAITING, PictureState.LIVE -> return
    }
    Column(
        modifier = modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(message),
            style = MaterialTheme.typography.bodyLarge,
            color = PeeringColors.muted,
            textAlign = TextAlign.Center,
        )
        if (picture == PictureState.STALLED || picture == PictureState.FAILED) {
            TextButton(onClick = onRetry) { Text(stringResource(R.string.overlay_picture_retry), maxLines = 1) }
        }
    }
}

@Composable
internal fun PicturePlaceholder(hostName: String?, modifier: Modifier = Modifier) {
    val description = stringResource(R.string.remote_waiting_for_video)
    Column(
        modifier = modifier.padding(24.dp).semantics { contentDescription = description },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PeeringSpinner(size = 18.dp, color = PeeringColors.muted)
        if (!hostName.isNullOrEmpty()) {
            Text(hostName, style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint, textAlign = TextAlign.Center, maxLines = 1)
        }
    }
}
