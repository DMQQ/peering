package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.arrive

/**
 * The Connect layout: the header, then paired computers, then Nearby, then the one way to add another. Cards are
 * outlined and sit directly on the page; a first-connection note stands in for the paired list until there is one.
 */
@Composable
fun ConnectScreen(state: ConnectUiState, actions: ConnectActions, modifier: Modifier = Modifier, bottomClearance: Dp = 24.dp) {
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(top = 16.dp, bottom = bottomClearance),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        ConnectHeader()
        state.message?.let { message ->
            Text(stringResource(message.messageRes()), style = MaterialTheme.typography.bodySmall, color = PeeringColors.danger)
        }
        if (state.listing.paired.isEmpty()) {
            FirstConnectionCard(Modifier.arrive(delayMillis = 140))
        } else {
            PairedSection(state.listing.paired, actions, Modifier.arrive(delayMillis = 140))
        }
        NearbySection(state.nearbyPhase, state.listing.nearby, actions, Modifier.arrive(delayMillis = 210))
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            PrimaryButton(stringResource(R.string.connect_pair_new), onClick = { entryOpen = true })
            LinkButton(stringResource(R.string.connect_by_address), onClick = { addressOpen = true }, modifier = Modifier.fillMaxWidth())
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
    if (addressOpen) {
        ManualAddressSheet(
            onConnect = { host, port -> addressOpen = false; actions.onConnectAddress(host, port) },
            onDismiss = { addressOpen = false },
        )
    }
}
