package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringRow
import pl.dmq.peering.ui.theme.SectionLabel
import pl.dmq.peering.ui.theme.arrive

/** The Connect layout: header, then one card holding Nearby, Another network and Trusted Macs, as on the iPhone. */
@Composable
fun ConnectScreen(state: ConnectUiState, actions: ConnectActions, modifier: Modifier = Modifier) {
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp)
            .padding(top = 16.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(28.dp),
    ) {
        ConnectHeader()
        OutlinedPanel(modifier = Modifier.fillMaxWidth().arrive(delayMillis = 210), contentPadding = PaddingValues(0.dp)) {
            NearbySection(state.nearbyPhase, state.listing.nearby, actions)
            Divider()
            AnotherNetwork(onClick = { entryOpen = true })
            Divider()
            TrustedSection(state.listing.paired, actions)
        }
        state.message?.let { message ->
            Text(
                text = stringResource(message.messageRes()),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
        }
    }
    if (entryOpen) {
        HostIdEntrySheet(
            state = state.entry,
            onTextChanged = actions.onEntryTextChanged,
            onSubmit = actions.onEntrySubmit,
            onScan = actions.onScan?.let { scan -> { entryOpen = false; scan() } },
            onDismiss = { entryOpen = false },
        )
    }
}

@Composable
private fun Divider() = HorizontalDivider(color = PeeringColors.ink.copy(alpha = 0.07f))

@Composable
private fun AnotherNetwork(onClick: () -> Unit) {
    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionLabel(stringResource(R.string.connect_another_network), Icons.Filled.Language)
        PeeringRow(onClick = onClick) {
            IconTile(Icons.Filled.Tag)
            Column(modifier = Modifier.weight(1f).padding(start = 12.dp)) {
                Text(
                    stringResource(R.string.connect_pair_elsewhere_title),
                    style = MaterialTheme.typography.titleMedium,
                    color = PeeringColors.ink,
                )
                Text(
                    stringResource(R.string.connect_pair_elsewhere_body),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.muted,
                    modifier = Modifier.padding(top = 1.dp),
                )
            }
        }
    }
}

@Composable
private fun TrustedSection(hosts: List<HostRow>, actions: ConnectActions) {
    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionLabel(stringResource(R.string.connect_paired_heading), Icons.Filled.VerifiedUser)
        if (hosts.isEmpty()) {
            Text(
                text = stringResource(R.string.connect_paired_empty),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.faint,
            )
        }
        hosts.forEach { row ->
            HostRowItem(row, paired = true, onOpen = { actions.onConnect(row.id) }, onForget = { actions.onForget(row.id) })
        }
    }
}
