package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.SearchOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.QuietButton
import pl.dmq.peering.ui.theme.SectionLabel

/** Macs on this network, or the reason there are none: no network, still looking, or nothing answered. */
@Composable
internal fun NearbySection(
    phase: NearbyPhase,
    hosts: List<HostRow>,
    actions: ConnectActions,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel(stringResource(R.string.connect_nearby_heading), Icons.Filled.Sensors, Modifier.weight(1f))
            if (phase != NearbyPhase.NoNetwork) {
                IconButton(onClick = actions.onSearchAgain, modifier = Modifier.size(36.dp)) {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription = stringResource(R.string.connect_search_again),
                        tint = PeeringColors.muted,
                    )
                }
            }
        }
        when (phase) {
            NearbyPhase.NoNetwork -> EmptyState(
                icon = Icons.Filled.WifiOff,
                title = stringResource(R.string.connect_no_network_title),
                body = stringResource(R.string.connect_no_network_body),
                modifier = Modifier.padding(vertical = 8.dp),
                action = {
                    QuietButton(onClick = actions.onOpenWifiSettings) {
                        Text(stringResource(R.string.connect_open_wifi_settings))
                    }
                },
            )
            NearbyPhase.Searching -> Searching()
            NearbyPhase.NoneFound -> NoneFound(actions.onSearchAgain)
            NearbyPhase.Found -> {
                hosts.forEach { row ->
                    HostRowItem(row, paired = false, onOpen = { actions.onPair(row.id) }, onForget = {})
                }
                Text(
                    text = pluralStringResource(R.plurals.connect_macs_found, hosts.size, hosts.size),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.faint,
                )
            }
        }
    }
}

@Composable
private fun Searching() {
    Row(modifier = Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(color = PeeringColors.muted, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            text = stringResource(R.string.connect_searching),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
    }
}

@Composable
private fun NoneFound(onSearchAgain: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(vertical = 4.dp)) {
        EmptyState(
            icon = Icons.Outlined.SearchOff,
            title = stringResource(R.string.connect_none_title),
            body = stringResource(R.string.connect_none_body),
        )
        listOf(R.string.connect_tip_same_network, R.string.connect_tip_host_running, R.string.connect_tip_permission)
            .forEach { tip ->
                Row(verticalAlignment = Alignment.Top) {
                    Text("•", color = PeeringColors.faint, modifier = Modifier.width(18.dp))
                    Text(
                        text = stringResource(tip),
                        style = MaterialTheme.typography.bodySmall,
                        color = PeeringColors.muted,
                    )
                }
            }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            QuietButton(onClick = onSearchAgain) { Text(stringResource(R.string.connect_search_again)) }
        }
    }
}
