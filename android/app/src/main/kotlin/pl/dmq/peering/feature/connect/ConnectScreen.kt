package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.arrive

/** The Connect layout: the header, a first-connection card until a computer is trusted, then one card holding Nearby, Another network and Trusted computers. */
@Composable
fun ConnectScreen(state: ConnectUiState, actions: ConnectActions, modifier: Modifier = Modifier, bottomClearance: androidx.compose.ui.unit.Dp = 24.dp) {
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp)
            .padding(top = 16.dp, bottom = bottomClearance),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        ConnectHeader()
        state.message?.let { message ->
            Text(stringResource(message.messageRes()), style = PeeringText.footnote, color = PeeringColors.danger)
        }
        if (state.listing.paired.isEmpty()) FirstConnectionCard(Modifier.arrive(delayMillis = 140))
        Column(Modifier.fillMaxWidth().cardBackground().arrive(delayMillis = 210)) {
            NearbySection(state.nearbyPhase, state.listing.nearby, actions, onConnectByAddress = { addressOpen = true })
            ControlsDivider()
            AnotherNetworkSection(onClick = { entryOpen = true })
            ControlsDivider()
            TrustedSection(state.listing.paired, actions)
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
