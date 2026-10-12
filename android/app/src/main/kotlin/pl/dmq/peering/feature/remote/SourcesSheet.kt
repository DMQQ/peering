package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceKind

/**
 * Lists what the computer can show as cards with live pictures, grouped into displays, applications and windows,
 * and switches the picture to the one the user taps. The host is asked to keep the pictures fresh while this is open.
 */
@Composable
fun SourcesSheet(
    catalog: CaptureCatalog?,
    chosen: CaptureSource?,
    presenter: SourcesPresenter,
    onDismiss: () -> Unit,
) {
    val state = remember(catalog, chosen) { presenter.build(catalog, chosen) }
    DisposableEffect(presenter) {
        presenter.watchThumbnails(true)
        onDispose { presenter.watchThumbnails(false) }
    }
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.sources_title), scrollable = true) {
        if (catalog == null) {
            Loading()
        }
        state.sections.forEach { section ->
            SectionHeader(section.kind)
            if (section.tiles.isEmpty()) {
                if (catalog != null) {
                    EmptyState(
                        icon = AppIcons.display,
                        title = stringResource(R.string.sources_empty_title),
                        body = stringResource(R.string.sources_empty),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 16.dp),
                    )
                }
            }
            section.tiles.chunked(COLUMNS).forEach { pair ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    pair.forEach { tile ->
                        SourceCard(
                            tile = tile,
                            onClick = {
                                presenter.choose(tile)
                                onDismiss()
                            },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    if (pair.size < COLUMNS) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun Loading() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PeeringSpinner(color = PeeringColors.muted)
        Text(
            text = stringResource(R.string.sources_waiting),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
    }
}

@Composable
private fun SectionHeader(kind: CaptureSourceKind) {
    Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp)) {
        Text(
            text = stringResource(kind.titleRes()),
            style = MaterialTheme.typography.titleSmall,
            color = PeeringColors.muted,
        )
    }
}

private fun CaptureSourceKind.titleRes(): Int = when (this) {
    CaptureSourceKind.DISPLAY -> R.string.sources_section_displays
    CaptureSourceKind.APPLICATION -> R.string.sources_section_applications
    CaptureSourceKind.WINDOW -> R.string.sources_section_windows
}

private const val COLUMNS = 2
