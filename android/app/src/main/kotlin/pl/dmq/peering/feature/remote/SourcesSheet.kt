package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceKind

/** Lists what the Mac can show, and switches the picture to the one the user taps. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SourcesSheet(
    catalog: CaptureCatalog?,
    chosen: CaptureSource?,
    presenter: SourcesPresenter,
    onDismiss: () -> Unit,
) {
    val state = remember(catalog, chosen) { presenter.build(catalog, chosen) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = stringResource(R.string.sources_title),
                style = MaterialTheme.typography.headlineSmall,
                color = PeeringColors.ink,
            )
            if (catalog == null) {
                Text(
                    text = stringResource(R.string.sources_waiting),
                    style = MaterialTheme.typography.bodyMedium,
                    color = PeeringColors.muted,
                )
            }
            state.sections.forEach { section ->
                Text(
                    text = stringResource(section.kind.titleRes()),
                    style = MaterialTheme.typography.titleSmall,
                    color = PeeringColors.muted,
                )
                if (section.tiles.isEmpty()) {
                    Text(
                        text = stringResource(R.string.sources_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = PeeringColors.muted,
                    )
                }
                section.tiles.forEach { tile ->
                    SourceTileRow(
                        tile = tile,
                        onClick = {
                            presenter.choose(tile)
                            onDismiss()
                        },
                    )
                }
            }
        }
    }
}

private fun CaptureSourceKind.titleRes(): Int = when (this) {
    CaptureSourceKind.DISPLAY -> R.string.sources_section_displays
    CaptureSourceKind.APPLICATION -> R.string.sources_section_applications
    CaptureSourceKind.WINDOW -> R.string.sources_section_windows
}
