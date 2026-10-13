package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** What the middle of the canvas says while there is no live picture: a calm message, with Retry when asking again helps. */
@Composable
fun PictureStatus(picture: PictureState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    val message = when (picture) {
        PictureState.WAITING -> R.string.remote_waiting_for_video
        PictureState.STALLED -> R.string.remote_no_picture_yet
        PictureState.FAILED -> R.string.overlay_picture_failed
        PictureState.PAUSED -> R.string.overlay_picture_paused
        PictureState.LIVE -> return
    }
    Column(
        modifier = modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (picture == PictureState.WAITING) CircularProgressIndicator(color = PeeringColors.muted, strokeWidth = 2.dp)
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
