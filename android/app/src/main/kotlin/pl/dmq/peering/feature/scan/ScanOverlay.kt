package pl.dmq.peering.feature.scan

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** The close button over the picture and the line under the frame that says what to do, or what went wrong. */
@Composable
internal fun ScanOverlay(notice: ScanOutcome?, onClose: () -> Unit, showHint: Boolean, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize()) {
        IconButton(
            onClick = onClose,
            modifier = Modifier.align(Alignment.TopStart).padding(12.dp).background(Scrim, CircleShape),
        ) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.scan_close), tint = PeeringColors.ink)
        }
        if (showHint) {
            val (text, color) = when (notice) {
                ScanOutcome.NotAPairingCode -> R.string.scan_not_pairing_code to PeeringColors.danger
                ScanOutcome.WrongCode -> R.string.scan_code_mismatch to PeeringColors.danger
                ScanOutcome.Used, null -> R.string.scan_hint to PeeringColors.ink
            }
            Text(
                text = stringResource(text),
                style = MaterialTheme.typography.bodyMedium,
                color = color,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 24.dp, vertical = 32.dp)
                    .background(Scrim, RoundedCornerShape(20.dp))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}

private val Scrim = PeeringColors.backdrop.copy(alpha = 0.72f)
