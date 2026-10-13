package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.CapsuleChip
import pl.dmq.peering.ui.kit.CircleIconButton
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

internal const val ID_PREFIX = 8

@Composable
internal fun NearbySection(
    phase: NearbyPhase,
    hosts: List<HostRow>,
    actions: ConnectActions,
    onConnectByAddress: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel(stringResource(R.string.connect_nearby_heading), AppIcons.nearby)
            if (hosts.isEmpty()) {
                Spacer(Modifier.width(8.dp))
                PeeringSpinner(size = 13.dp, color = PeeringColors.muted)
            }
            Spacer(Modifier.weight(1f))
            CapsuleChip(stringResource(R.string.connect_by_address), AppIcons.network, onConnectByAddress)
            Spacer(Modifier.width(8.dp))
            CircleIconButton(AppIcons.refresh, stringResource(R.string.connect_search_again), actions.onSearchAgain)
        }
        if (hosts.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                hosts.forEach { row ->
                    HostRowCard(row, detail = row.id.take(ID_PREFIX), up = true, onOpen = { actions.onPair(row.id) })
                }
            }
        }
        if (phase == NearbyPhase.NoNetwork) NoWifiNotice(actions.onOpenWifiSettings)
        Text(
            nearbyStatus(phase, hosts.size),
            style = PeeringText.caption,
            color = if (hosts.isEmpty()) PeeringColors.tertiary else PeeringColors.muted,
            modifier = Modifier.padding(vertical = if (hosts.isEmpty()) 4.dp else 0.dp),
        )
    }
}

@Composable
private fun nearbyStatus(phase: NearbyPhase, found: Int): String = when {
    found > 0 -> pluralStringResource(R.plurals.connect_macs_found, found, found)
    phase == NearbyPhase.NoneFound -> stringResource(R.string.connect_none_found)
    else -> stringResource(R.string.connect_searching)
}

@Composable
private fun NoWifiNotice(onOpenWifiSettings: () -> Unit) {
    Column(Modifier.fillMaxWidth().cardBackground().padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.connect_no_network_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        Text(stringResource(R.string.connect_no_network_body), style = PeeringText.caption, color = PeeringColors.muted)
        InkButton(onClick = onOpenWifiSettings, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.connect_open_wifi_settings))
        }
    }
}
