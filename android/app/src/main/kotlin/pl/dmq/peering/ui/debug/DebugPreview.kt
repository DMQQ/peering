package pl.dmq.peering.ui.debug

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NoPhotography
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodeContent
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.feature.pairing.PairingMessage
import pl.dmq.peering.feature.scan.ScanMessage
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.connect.ConnectActions
import pl.dmq.peering.feature.connect.ConnectScreen
import pl.dmq.peering.feature.connect.ConnectUiState
import pl.dmq.peering.feature.connect.HostListing
import pl.dmq.peering.feature.connect.HostRow
import pl.dmq.peering.feature.connect.HostStatus
import pl.dmq.peering.feature.connect.NearbyPhase
import pl.dmq.peering.ui.theme.peeringBackdrop

/** Debug builds only: `adb shell am start -n pl.dmq.peering/.MainActivity --es preview connect_none` renders a screen with sample data. */
const val PREVIEW_EXTRA = "preview"

private val sampleNearby = listOf(HostRow("AA9F6993", "Damian's MacBook Pro", HostStatus.Online))
private val samplePaired = listOf(
    HostRow("B1", "Studio Mac mini", HostStatus.Connected),
    HostRow("B2", "Damian's MacBook Pro", HostStatus.Online),
    HostRow("B3", "Office iMac", HostStatus.Unknown),
)

@Composable
fun DebugPreview(name: String) {
    Box(Modifier.fillMaxSize().peeringBackdrop().windowInsetsPadding(WindowInsets.systemBars)) {
        when (name) {
            "connect_found" -> connect(NearbyPhase.Found, HostListing(samplePaired, sampleNearby))
            "connect_searching" -> connect(NearbyPhase.Searching, HostListing(emptyList(), emptyList()))
            "connect_none" -> connect(NearbyPhase.NoneFound, HostListing(emptyList(), emptyList()))
            "pairing_compare" -> PairingCodeContent(PairingCodeScreen.Comparing("482917"), PairingActions(onScan = {}))
            "pairing_wait" -> PairingCodeContent(PairingCodeScreen.Waiting, PairingActions())
            "pairing_done" -> PairingCodeContent(PairingCodeScreen.Done, PairingActions())
            "pairing_failed" -> PairingCodeContent(PairingCodeScreen.Failed(PairingMessage.Unreachable), PairingActions())
            "scan_denied" -> ScanMessage(
                icon = Icons.Filled.NoPhotography,
                title = stringResource(R.string.scan_denied_title),
                text = stringResource(R.string.scan_denied),
                action = stringResource(R.string.scan_open_settings),
            )
            "connect_nonetwork" -> connect(NearbyPhase.NoNetwork, HostListing(samplePaired.take(1), emptyList()))
        }
    }
}

@Composable
private fun connect(phase: NearbyPhase, listing: HostListing) {
    ConnectScreen(ConnectUiState(listing = listing, nearbyPhase = phase), ConnectActions(onScan = {}))
}
