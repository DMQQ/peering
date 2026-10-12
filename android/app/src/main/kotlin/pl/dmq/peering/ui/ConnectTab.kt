package pl.dmq.peering.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.connect.ConnectPresenter
import pl.dmq.peering.feature.connect.ConnectRoute
import pl.dmq.peering.feature.onboarding.OnboardingRoute
import pl.dmq.peering.feature.pairing.PairingCodePresenter
import pl.dmq.peering.feature.pairing.PairingCodeRoute
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.feature.scan.QrScannerRoute
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.feature.scan.hostIdScanOutcome
import pl.dmq.peering.ui.wiring.ControllerPairingSession
import pl.dmq.peering.ui.nav.SessionScreens

/** Where a scan goes: a Mac to pair with, or the six digits being compared on this screen. */
private enum class ScanPurpose { FindMac, ConfirmCode }

/** The Connect tab: first run, then the hosts, pairing, and the session a connect opened. */
@Composable
internal fun ConnectTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val active by wiring.holder.active.collectAsState()
    var onboarding by remember { mutableStateOf(!wiring.firstRun.isComplete()) }
    var pairing by remember { mutableStateOf<PairingCodePresenter?>(null) }
    var showingSession by rememberSaveable { mutableStateOf(false) }
    var scanning by remember { mutableStateOf<ScanPurpose?>(null) }
    val connect = remember(wiring, scope) {
        ConnectPresenter(
            hosts = wiring.discovery,
            presence = wiring.presence,
            qrSource = wiring.qrSource,
            onConnect = { hostId ->
                wiring.connectPaired(hostId)
                showingSession = true
            },
            onPair = { hostId ->
                val session = wiring.startPairing(hostId)
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
                onboarding = false
                scanning = null
                wiring.firstRun.markComplete()
            },
            scope = scope,
        )
    }
    DisposableEffect(wiring) {
        wiring.presence.setShown(true)
        onDispose { wiring.presence.setShown(false) }
    }
    val session = active
    val presenting = pairing
    Box(modifier = Modifier.fillMaxSize()) {
        when {
            scanning != null -> QrScannerRoute(
                onCode = { text -> scanned(scanning, text, wiring.qrSource, presenting) },
                onClose = { scanning = null },
            )
            onboarding -> OnboardingRoute(
                store = wiring.firstRun,
                onScanPairingCode = { scanning = ScanPurpose.FindMac },
                onFinished = { onboarding = false },
            )
            presenting != null -> PairingCodeRoute(
                presenter = presenting,
                onFinished = { pairing = null },
                onScanRequested = { scanning = ScanPurpose.ConfirmCode },
            )
            showingSession && session != null -> SessionScreens(
                active = session,
                picture = wiring.picture,
                drafts = wiring.drafts,
                folderRecents = wiring.folderRecents,
                clock = wiring.clock,
                onClose = { showingSession = false },
            )
            else -> ConnectRoute(
                presenter = connect,
                onScanRequested = { scanning = ScanPurpose.FindMac },
            )
        }
    }
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
