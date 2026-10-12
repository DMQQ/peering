package pl.dmq.peering.feature.connect

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.theme.peeringBackdrop
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier

private fun ignore() = Unit

@Suppress("UNUSED_PARAMETER")
private fun ignore(text: String) = Unit

@Suppress("UNUSED_PARAMETER")
private fun ignore(host: String, port: String) = Unit

private val previewActions = ConnectActions(
    onConnect = ::ignore,
    onConnectVia = ::ignoreVia,
    onPair = ::ignore,
    onRename = ::ignore,
    onDismissMessage = ::ignore,
    onForget = ::ignore,
    onConnectAddress = ::ignore,
    onSearchAgain = ::ignore,
    onOpenWifiSettings = ::ignore,
    onEntryTextChanged = ::ignore,
    onEntrySubmit = ::ignore,
    onScan = ::ignore,
)

private val pairedRows = listOf(
    HostRow("B1", "Studio computer", HostStatus.Connected, HostRoute.Local),
    HostRow("B2", "Laptop", HostStatus.Online, HostRoute.Relay),
    HostRow("B3", "Office desktop", HostStatus.Unknown, HostRoute.None),
)

private val nearbyRows = listOf(HostRow("N1", "Spare laptop", HostStatus.Online, HostRoute.Local))

@Composable
private fun Frame(state: ConnectUiState) {
    PeeringTheme { Box(Modifier.peeringBackdrop()) { ConnectScreen(state, previewActions, AppProtection(enabled = false, available = true, onChange = ::ignoreFlag)) } }
}

@Preview(name = "Connect, computers found", showBackground = true, heightDp = 1000)
@Composable
private fun ConnectFoundPreview() = Frame(ConnectUiState(HostListing(pairedRows, nearbyRows), NearbyPhase.Found))

@Preview(name = "Connect, searching", showBackground = true, heightDp = 800)
@Composable
private fun ConnectSearchingPreview() = Frame(ConnectUiState(HostListing(pairedRows, emptyList()), NearbyPhase.Searching))

@Preview(name = "Connect, nothing found", showBackground = true, heightDp = 900)
@Composable
private fun ConnectNoneFoundPreview() = Frame(ConnectUiState(HostListing(pairedRows, emptyList()), NearbyPhase.NoneFound))

@Preview(name = "Connect, no network, nothing paired", showBackground = true, heightDp = 900)
@Composable
private fun ConnectNoNetworkPreview() = Frame(ConnectUiState(HostListing.EMPTY, NearbyPhase.NoNetwork))

@Suppress("UNUSED_PARAMETER")
private fun ignoreVia(hostId: String, via: ConnectVia) = Unit

@Suppress("UNUSED_PARAMETER")
private fun ignoreFlag(enabled: Boolean) = Unit
