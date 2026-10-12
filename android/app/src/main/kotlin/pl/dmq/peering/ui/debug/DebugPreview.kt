package pl.dmq.peering.ui.debug

import android.util.Log
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodeContent
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.feature.pairing.PairingMessage
import pl.dmq.peering.feature.scan.ScanAction
import pl.dmq.peering.feature.scan.ScanMessage
import pl.dmq.peering.session.controller.PairingCodeError
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.onboarding.OnboardingRoute
import pl.dmq.peering.feature.onboarding.OnboardingStep
import pl.dmq.peering.feature.connect.FirstConnectionScreen
import pl.dmq.peering.feature.connect.ManualAddressSheet
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.feature.pairing.HostIdEntryState
import pl.dmq.peering.feature.connect.ConnectActions
import pl.dmq.peering.feature.connect.AppProtection
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
            "pairing_entry" -> PairingCodeContent(PairingCodeScreen.EnteringCode(0, null), previewPairing())
            "pairing_wrong" -> PairingCodeContent(
                PairingCodeScreen.EnteringCode(1, PairingCodeError.WrongCode),
                previewPairing(),
            )
            "pairing_too_many" -> PairingCodeContent(PairingCodeScreen.Failed(PairingMessage.TooManyAttempts), previewPairing(scan = false))
            "pairing_connecting" -> PairingCodeContent(PairingCodeScreen.Connecting, previewPairing(scan = false))
            "pairing_wait" -> PairingCodeContent(PairingCodeScreen.Waiting, previewPairing(scan = false))
            "pairing_done" -> PairingCodeContent(PairingCodeScreen.Done, previewPairing(scan = false))
            "pairing_failed" -> PairingCodeContent(PairingCodeScreen.Failed(PairingMessage.Unreachable, "ConnectException: failed to connect to /192.168.1.20 (port 51515)"), previewPairing(scan = false))
            "scan_denied" -> ScanMessage(
                icon = AppIcons.camera,
                title = stringResource(R.string.scan_denied_title),
                text = stringResource(R.string.scan_denied),
                action = ScanAction(stringResource(R.string.scan_open_settings), note("open settings")),
            )
            "onboarding_landing" -> sampleOnboarding(OnboardingStep.LANDING)
            "onboarding_1" -> sampleOnboarding(OnboardingStep.INSTALL)
            "onboarding_2" -> sampleOnboarding(OnboardingStep.PAIR)
            "onboarding_3" -> sampleOnboarding(OnboardingStep.SOURCES)
            "onboarding_4" -> sampleOnboarding(OnboardingStep.CONTROLS)
            "onboarding_5" -> sampleOnboarding(OnboardingStep.FOLLOWS)
            "onboarding_6" -> sampleOnboarding(OnboardingStep.MOSAIC)
            "onboarding_7" -> sampleOnboarding(OnboardingStep.NOTIFICATIONS)
            "onboarding_8" -> sampleOnboarding(OnboardingStep.PLANS)
            "connect_address" -> {
                connect(NearbyPhase.Found, HostListing(emptyList(), sampleNearby))
                ManualAddressSheet(onConnect = { host, port -> note("connect $host:$port") }, onDismiss = note("dismiss"))
            }
            "connect_entry" -> {
                connect(NearbyPhase.Found, HostListing(emptyList(), sampleNearby))
                HostIdEntrySheet(HostIdEntryState(), { note("text $it") }, note("submit"), note("scan"), note("dismiss"))
            }
            "first_connection" -> FirstConnectionScreen(
                ConnectUiState(listing = HostListing(emptyList(), sampleNearby), nearbyPhase = NearbyPhase.Found),
                previewConnect(),
                onSkip = note("skip"),
            )
            "connect_nonetwork" -> connect(NearbyPhase.NoNetwork, HostListing(samplePaired.take(1), emptyList()))
        }
    }
}

@Composable
private fun connect(phase: NearbyPhase, listing: HostListing) {
    ConnectScreen(ConnectUiState(listing = listing, nearbyPhase = phase), previewConnect(), AppProtection(enabled = false, available = true, onChange = { note("protect $it") }))
}

@Composable
private fun sampleOnboarding(step: OnboardingStep) {
    OnboardingRoute(store = SampleFirstRun, billing = SampleBilling, onFinished = { Log.i(TAG, "first run finished") }, startAt = step)
}

private const val TAG = "PeeringPreview"

private fun note(what: String): () -> Unit = { Log.i(TAG, what) }

private fun previewPairing(scan: Boolean = true) = PairingActions(
    onDigitsEntered = { digits -> Log.i(TAG, "digits $digits") },
    onCancel = note("cancel"),
    onFinished = note("finished"),
    onScan = if (scan) note("scan") else null,
)

private fun previewConnect() = ConnectActions(
    onConnect = { id -> Log.i(TAG, "connect $id") },
    onConnectVia = { id, via -> Log.i(TAG, "connect $id via $via") },
    onPair = { id -> Log.i(TAG, "pair $id") },
    onRename = { id, name -> Log.i(TAG, "rename $id $name") },
    onDismissMessage = note("dismiss message"),
    onForget = { id -> Log.i(TAG, "forget $id") },
    onConnectAddress = { host, port -> Log.i(TAG, "address $host:$port") },
    onSearchAgain = note("search again"),
    onOpenWifiSettings = note("wifi settings"),
    onEntryTextChanged = { text -> Log.i(TAG, "entry $text") },
    onEntrySubmit = note("entry submit"),
    onScan = note("scan"),
)
