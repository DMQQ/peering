package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.CapsuleChip
import pl.dmq.peering.ui.kit.CircleIconButton
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.theme.SectionLabel

/** Computers on this network, or the reason there are none: no network, still looking, or nothing answered. */
@Composable
internal fun NearbySection(
    phase: NearbyPhase,
    hosts: List<HostRow>,
    actions: ConnectActions,
    onConnectByAddress: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel(stringResource(R.string.connect_nearby_heading), AppIcons.nearby)
            if (phase == NearbyPhase.Searching) {
                Spacer(Modifier.width(8.dp))
                PeeringSpinner(size = 13.dp, color = PeeringColors.muted)
            }
            Spacer(Modifier.weight(1f))
            CapsuleChip(stringResource(R.string.connect_by_address), AppIcons.network, onConnectByAddress)
            if (phase != NearbyPhase.NoNetwork) {
                Spacer(Modifier.width(8.dp))
                CircleIconButton(AppIcons.refresh, stringResource(R.string.connect_search_again), actions.onSearchAgain)
            }
        }
        when (phase) {
            NearbyPhase.NoNetwork -> EmptyState(
                icon = AppIcons.wifiOff,
                title = stringResource(R.string.connect_no_network_title),
                body = stringResource(R.string.connect_no_network_body),
                modifier = Modifier.padding(vertical = 8.dp),
                action = { QuietButton(onClick = actions.onOpenWifiSettings) { Text(stringResource(R.string.connect_open_wifi_settings)) } },
            )
            NearbyPhase.Searching -> Text(stringResource(R.string.connect_searching), style = PeeringText.caption, color = PeeringColors.tertiary, modifier = Modifier.padding(vertical = 4.dp))
            NearbyPhase.NoneFound -> NoneFound()
            NearbyPhase.Found -> {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    hosts.forEach { row -> HostRowItem(row, paired = false, onOpen = { actions.onPair(row.id) }, onForget = {}) }
                }
                Text(
                    pluralStringResource(R.plurals.connect_macs_found, hosts.size, hosts.size),
                    style = PeeringText.caption,
                    color = PeeringColors.muted,
                )
            }
        }
    }
}

@Composable
private fun NoneFound() {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 4.dp)) {
        Text(stringResource(R.string.connect_none_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        Text(stringResource(R.string.connect_none_body), style = PeeringText.caption, color = PeeringColors.muted)
        listOf(R.string.connect_tip_same_network, R.string.connect_tip_host_running, R.string.connect_tip_permission).forEach { tip ->
            Row(verticalAlignment = Alignment.Top) {
                Text("•", style = PeeringText.caption, color = PeeringColors.tertiary, modifier = Modifier.width(16.dp))
                Text(stringResource(tip), style = PeeringText.caption, color = PeeringColors.muted)
            }
        }
    }
}
