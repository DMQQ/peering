package pl.dmq.peering.feature.remote

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import pl.dmq.peering.R

/** The link being put back. A picture that is missing is told in the middle of the canvas, not here. */
@Composable
fun SessionSnackbar(
    state: SessionOverlayState,
    modifier: Modifier = Modifier,
) {
    if (!state.reconnecting) return
    val computer = state.hostName ?: stringResource(R.string.remote_computer_fallback)
    Snackbar(
        shape = MaterialTheme.shapes.large,
        modifier = modifier.semantics { liveRegion = LiveRegionMode.Polite },
    ) { Text(stringResource(R.string.remote_reconnecting, computer), maxLines = 2) }
}
