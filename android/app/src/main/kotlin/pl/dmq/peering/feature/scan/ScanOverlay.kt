package pl.dmq.peering.feature.scan

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SheetToolbar
import pl.dmq.peering.ui.kit.glassSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The title and Cancel capsule over the picture, and the glass line under the frame that says what to do, or what went wrong. */
@Composable
internal fun ScanOverlay(notice: ScanOutcome?, onClose: () -> Unit, showHint: Boolean, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize()) {
        SheetToolbar(
            cancel = stringResource(R.string.connect_cancel),
            onCancel = onClose,
            title = stringResource(R.string.scan_title),
            modifier = Modifier.windowInsetsPadding(WindowInsets.statusBars),
        )
        if (showHint) {
            val (text, color) = when (notice) {
                ScanOutcome.NotAPairingCode -> R.string.scan_not_pairing_code to PeeringColors.danger
                ScanOutcome.WrongCode -> R.string.scan_code_mismatch to PeeringColors.danger
                ScanOutcome.Used, null -> R.string.scan_hint to PeeringColors.ink
            }
            Text(
                text = stringResource(text),
                style = PeeringText.footnote,
                color = color,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(horizontal = 24.dp, vertical = 28.dp)
                    .glassSurface(CircleShape)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}
