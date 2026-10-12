package pl.dmq.peering.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.feature.connect.ConnectPresenter
import pl.dmq.peering.feature.connect.ConnectRoute
import pl.dmq.peering.feature.connect.FirstConnectionScreen
import pl.dmq.peering.feature.connect.rememberConnectActions
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.feature.onboarding.OnboardingRoute
import pl.dmq.peering.feature.pairing.PairingCodePresenter
import pl.dmq.peering.feature.pairing.PairingCodeRoute
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.feature.scan.QrScannerRoute
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.feature.scan.hostIdScanOutcome
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.ControllerPairingSession
import pl.dmq.peering.ui.nav.SessionScreens

/** Where a scan goes: a Mac to pair with, or the six digits being compared on this screen. */
private enum class ScanPurpose { FindMac, ConfirmCode }

/** The Connect tab: first run, then the hosts, pairing, and the session a connect opened. */
@Composable
internal fun ConnectTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val active by wiring.holder.active.collectAsState()
    var onboarding by remember { mutableStateOf(!wiring.firstRun.isComplete()) }
    var pairing by remember { mutableStateOf<PairingCodePresenter?>(null) }
    var pairingSession by remember { mutableStateOf<ActiveSession?>(null) }
    var firstConnectionDismissed by rememberSaveable { mutableStateOf(false) }
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
                pairingSession = session
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
                onboarding = false
                scanning = null
                wiring.firstRun.markComplete()
            },
            onConnectAddress = { address ->
                val session = wiring.startPairingByAddress(PeerAddress(address.host, address.port))
                pairingSession = session
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
                onboarding = false
                wiring.firstRun.markComplete()
            },
            scope = scope,
            network = wiring.network,
        )
    }
    DisposableEffect(wiring) {
        wiring.presence.setShown(true)
        onDispose { wiring.presence.setShown(false) }
    }
    // The holder runs one session; once another replaces the one being paired, its screen has nothing left to show.
    LaunchedEffect(active) {
        if (pairing != null && active !== pairingSession) pairing = null
    }
    val connectState by connect.state.collectAsState()
    val firstConnection = !firstConnectionDismissed && connectState.listing.paired.isEmpty()
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
                billing = StorePaywallBilling(wiring.billing) { context.findActivity() },
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
                settings = wiring.settings,
                billing = wiring.billing,
                relayAllowance = wiring.relayAllowance,
                clock = wiring.clock,
                onClose = { showingSession = false },
                onDisconnect = {
                    showingSession = false
                    wiring.holder.end()
                },
            )
            firstConnection -> FirstConnectionScreen(
                state = connectState,
                actions = rememberConnectActions(connect) { scanning = ScanPurpose.FindMac },
                onSkip = { firstConnectionDismissed = true },
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
