package pl.dmq.peering.feature.scan

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import pl.dmq.peering.ui.theme.PillShape
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.chipSurface
import pl.dmq.peering.ui.theme.PeeringColors

/** A top app bar with a close button over the picture, and the line under the frame that says what to do, or what went wrong. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScanOverlay(notice: ScanOutcome?, onClose: () -> Unit, showHint: Boolean, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize()) {
        CenterAlignedTopAppBar(
            title = { Text(stringResource(R.string.scan_title), style = MaterialTheme.typography.titleLarge) },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(AppIcons.close, contentDescription = stringResource(R.string.connect_cancel)) }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = Color.Transparent,
                titleContentColor = PeeringColors.ink,
                navigationIconContentColor = PeeringColors.ink,
            ),
        )
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
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(horizontal = 24.dp, vertical = 28.dp)
                    .chipSurface(PillShape)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}
