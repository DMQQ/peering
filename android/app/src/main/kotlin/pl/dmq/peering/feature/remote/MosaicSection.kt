package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlIcon
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.TonalButton
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.CaptureSource

/** What the Apps panel knows about mosaics; null where the computer cannot compose one. */
data class MosaicPanel(val active: MosaicLayout?, val remembered: MosaicLayout?) {
    /** The arrangement the edit rows describe: the one on screen, else the last one asked for. */
    val arrangement: MosaicLayout? get() = active ?: remembered

    val sources: List<CaptureSource> get() = arrangement?.tiles?.map { it.source }.orEmpty()
}

/** The way in, before any mosaic has been built this session. */
@Composable
internal fun MosaicEntryRow(onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().rowSurface().tappable(onClick).padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ControlIcon(AppIcons.grid)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(stringResource(R.string.mosaic_title), style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
            Text(stringResource(R.string.mosaic_subtitle), style = PeeringText.caption2, color = PeeringColors.muted)
        }
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
    }
}

/** Once a mosaic exists: the way back to it while a single source is up, and the way to change what is in it. */
@Composable
internal fun MosaicEditRows(panel: MosaicPanel, onReturn: () -> Unit, onEdit: () -> Unit) {
    Column(Modifier.fillMaxWidth().rowSurface()) {
        if (panel.active == null && panel.remembered != null) {
            val count = panel.remembered.tiles.size
            ActionRow(stringResource(R.string.mosaic_back), pluralStringResource(R.plurals.sources_windows, count, count), onReturn)
            ControlsDivider()
        }
        ActionRow(stringResource(R.string.mosaic_edit), null, onEdit)
    }
}

@Composable
private fun ActionRow(title: String, detail: String?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().tappable(onClick).padding(horizontal = 8.dp, vertical = 8.dp)
            .semantics { contentDescription = listOfNotNull(title, detail).joinToString(", ") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(AppIcons.grid, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
        Text(title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
        Spacer(Modifier.weight(1f))
        detail?.let { Text(it, style = PeeringText.caption2, color = PeeringColors.muted) }
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(16.dp))
    }
}

/** The bar pinned under the picker: how many are picked, a way back to the list, and Start once there are two or more. */
@Composable
internal fun MosaicPickerBar(picks: MosaicPicks, onBack: () -> Unit, onStart: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, bottom = 10.dp).rowSurface().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            val count = picks.sources.size
            Text(
                if (count == 0) stringResource(R.string.mosaic_pick_two) else stringResource(R.string.mosaic_picked, count),
                style = PeeringText.captionSemibold,
                color = PeeringColors.muted,
                modifier = Modifier.weight(1f),
            )
            Text(stringResource(R.string.mosaic_limit, MosaicLayout.MAXIMUM_TILES), style = PeeringText.caption2, color = PeeringColors.tertiary)
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TonalButton(onBack) { Text(stringResource(R.string.mosaic_back_to_sources), style = PeeringText.subheadlineMedium) }
            Spacer(Modifier.weight(1f))
            PrimaryButton(stringResource(R.string.mosaic_start), onStart, enabled = picks.canStart)
        }
    }
}
