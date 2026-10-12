package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.ui.kit.cardBackground

/**
 * The Connect layout: the header, a note until a first computer is trusted, then one card holding Nearby, Another
 * network and Trusted computers, and last the switch that protects them.
 */
@Composable
fun ConnectScreen(
    state: ConnectUiState,
    actions: ConnectActions,
    protection: AppProtection,
    modifier: Modifier = Modifier,
    bottomClearance: Dp = 36.dp,
) {
    var entryOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp)
            .padding(bottom = bottomClearance),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        ConnectHeader()
        state.message?.let { message -> FailureCard(message, actions.onDismissMessage) }
        if (state.listing.paired.isEmpty()) FirstConnectionCard(Modifier)
        Column(Modifier.fillMaxWidth().cardBackground()) {
            NearbySection(
                state.nearbyPhase, state.listing.nearby, actions,
                onConnectByAddress = { addressOpen = true },
                modifier = Modifier.padding(16.dp),
            )
            HorizontalDivider(color = DIVIDER)
            RemotePairingEntry(onOpen = { entryOpen = true }, modifier = Modifier.padding(16.dp))
            HorizontalDivider(color = DIVIDER)
            PairedSection(state.listing.paired, actions, Modifier.padding(16.dp))
        }
        ProtectionCard(protection)
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

private val DIVIDER = Color.White.copy(alpha = 0.1f)
