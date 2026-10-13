package pl.dmq.peering.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.connect.ConnectPresenter
import pl.dmq.peering.feature.connect.ConnectRoute
import pl.dmq.peering.feature.connect.ConnectUiState
import pl.dmq.peering.feature.connect.FirstConnectionRoute
import pl.dmq.peering.feature.connect.rememberConnectActions
import pl.dmq.peering.feature.onboarding.OnboardingRoute
import pl.dmq.peering.feature.pairing.PairingCodePresenter
import pl.dmq.peering.feature.pairing.PairingCodeRoute
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.feature.scan.QrScannerRoute
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.feature.scan.hostIdScanOutcome
import pl.dmq.peering.ui.nav.SessionScreens
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.ui.wiring.rememberAppProtection

/** The screen of one [ConnectStage]. [presenting] and [session] are what the tab saw when it composed, so a stage that is animating out keeps them. */
@Composable
internal fun ConnectStageContent(
    shown: ConnectStage,
    wiring: FeatureWiring,
    flow: ConnectFlow,
    connect: ConnectPresenter,
    connectState: ConnectUiState,
    presenting: PairingCodePresenter?,
    session: ActiveSession?,
) {
    val context = LocalContext.current
    when (shown) {
        ConnectStage.Scanner -> QrScannerRoute(
            onCode = { text -> scanned(flow.scanning, text, wiring.qrSource, presenting) },
            onClose = { flow.scanning = null },
        )
        ConnectStage.Onboarding -> OnboardingRoute(
            store = wiring.firstRun,
            billing = remember(wiring) { StorePaywallBilling(wiring.billing) { context.findActivity() } },
            onFinished = { flow.onboarding = false },
        )
        ConnectStage.Pairing -> presenting?.let { current ->
            PairingCodeRoute(
                presenter = current,
                onFinished = { finishPairing(wiring, flow, current, session) },
                onScanRequested = { flow.scanning = ScanPurpose.ConfirmCode },
                hostName = flow.pairingHostName,
            )
        }
        ConnectStage.Session -> session?.let { current -> SessionStage(wiring, flow, current) }
        ConnectStage.FirstConnection -> FirstConnectionRoute(
            state = connectState,
            actions = rememberConnectActions(connect) { flow.scanning = ScanPurpose.FindMac },
            pairing = presenting,
            onSkip = { flow.firstConnectionDismissed = true },
            onPairingFinished = { finishPairing(wiring, flow, presenting, session) },
            onScanCodeRequested = { flow.scanning = ScanPurpose.ConfirmCode },
            hostName = flow.pairingHostName,
        )
        ConnectStage.Hosts -> ConnectRoute(
            presenter = connect,
            protection = rememberAppProtection(),
            onScanRequested = { flow.scanning = ScanPurpose.FindMac },
        )
    }
}

@Composable
private fun SessionStage(wiring: FeatureWiring, flow: ConnectFlow, current: ActiveSession) {
    SessionScreens(
        active = current,
        picture = wiring.picture,
        settings = wiring.settings,
        devicePrefs = wiring.devicePrefs,
        macros = wiring.macros,
        billing = wiring.billing,
        relayAllowance = wiring.relayAllowance,
        onClose = { flow.showingSession = false },
        onDisconnect = {
            flow.showingSession = false
            wiring.holder.end()
        },
    )
}

/** Ends the session that was being paired unless the pairing asked to keep it, in which case it opens as the session. */
private fun finishPairing(wiring: FeatureWiring, flow: ConnectFlow, finished: PairingCodePresenter?, active: ActiveSession?) {
    if (finished?.state?.value?.keepsConnection == true) {
        flow.showingSession = true
    } else if (active === flow.pairingSession) {
        wiring.holder.end()
    }
    flow.pairing = null
}

private fun scanned(
    purpose: ScanPurpose?,
    text: String,
    qrSource: CameraQrSource,
    pairing: PairingCodePresenter?,
): ScanOutcome = when {
    purpose == ScanPurpose.ConfirmCode && pairing != null -> pairing.confirmScannedCode(text)
    purpose == ScanPurpose.FindMac -> hostIdScanOutcome(text).also { outcome ->
        if (outcome == ScanOutcome.Used) qrSource.offer(text)
    }
    else -> ScanOutcome.NotAPairingCode
}
