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
import pl.dmq.peering.ui.kit.Symbols
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodeContent
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.feature.pairing.PairingMessage
import pl.dmq.peering.feature.scan.ScanMessage
import pl.dmq.peering.session.controller.PairingCodeError
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.onboarding.OnboardingRoute
import pl.dmq.peering.feature.onboarding.OnboardingStep
import pl.dmq.peering.feature.connect.ManualAddressSheet
import pl.dmq.peering.feature.pairing.HostIdEntrySheet
import pl.dmq.peering.feature.pairing.HostIdEntryState
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
            "pairing_entry" -> PairingCodeContent(PairingCodeScreen.EnteringCode(0, null), PairingActions(onScan = {}))
            "pairing_wrong" -> PairingCodeContent(
                PairingCodeScreen.EnteringCode(1, PairingCodeError.WrongCode),
                PairingActions(onScan = {}),
            )
            "pairing_too_many" -> PairingCodeContent(PairingCodeScreen.Failed(PairingMessage.TooManyAttempts), PairingActions())
            "pairing_wait" -> PairingCodeContent(PairingCodeScreen.Waiting, PairingActions())
            "pairing_done" -> PairingCodeContent(PairingCodeScreen.Done, PairingActions())
            "pairing_failed" -> PairingCodeContent(PairingCodeScreen.Failed(PairingMessage.Unreachable, "ConnectException: failed to connect to /192.168.1.20 (port 51515)"), PairingActions())
            "scan_denied" -> ScanMessage(
                icon = Symbols.camera,
                title = stringResource(R.string.scan_denied_title),
                text = stringResource(R.string.scan_denied),
                action = stringResource(R.string.scan_open_settings),
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
                ManualAddressSheet(onConnect = { _, _ -> }, onDismiss = {})
            }
            "connect_entry" -> {
                connect(NearbyPhase.Found, HostListing(emptyList(), sampleNearby))
                HostIdEntrySheet(HostIdEntryState(), {}, {}, {}, {})
            }
            "connect_nonetwork" -> connect(NearbyPhase.NoNetwork, HostListing(samplePaired.take(1), emptyList()))
        }
    }
}

@Composable
private fun connect(phase: NearbyPhase, listing: HostListing) {
    ConnectScreen(ConnectUiState(listing = listing, nearbyPhase = phase), ConnectActions(onScan = {}))
}

@Composable
private fun sampleOnboarding(step: OnboardingStep) {
    OnboardingRoute(store = SampleFirstRun, billing = SampleBilling, onFinished = { Log.i("PeeringPreview", "first run finished") }, startAt = step)
}
