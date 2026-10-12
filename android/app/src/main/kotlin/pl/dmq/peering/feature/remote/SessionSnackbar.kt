package pl.dmq.peering.feature.remote

import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import pl.dmq.peering.R

/** Status that needs the user's eye: the link being put back, or a picture that stalled or failed, with Retry. */
@Composable
fun SessionSnackbar(
    state: SessionOverlayState,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val computer = state.hostName ?: stringResource(R.string.remote_computer_fallback)
    val retryable = state.picture == PictureState.STALLED || state.picture == PictureState.FAILED
    val message = when {
        state.reconnecting -> stringResource(R.string.remote_reconnecting, computer)
        state.picture == PictureState.STALLED -> stringResource(R.string.overlay_picture_stalled)
        state.picture == PictureState.FAILED -> stringResource(R.string.overlay_picture_failed)
        else -> return
    }
    Snackbar(
        modifier = modifier.semantics { liveRegion = LiveRegionMode.Polite },
        action = if (retryable && !state.reconnecting) {
            { TextButton(onClick = onRetry) { Text(stringResource(R.string.overlay_picture_retry)) } }
        } else {
            null
        },
    ) { Text(message) }
}
