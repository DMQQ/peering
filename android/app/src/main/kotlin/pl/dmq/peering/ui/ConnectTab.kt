package pl.dmq.peering.ui

import androidx.compose.animation.AnimatedContent
import pl.dmq.peering.ui.kit.motionTransition
import pl.dmq.peering.ui.kit.rememberMotionDistances
import pl.dmq.peering.ui.kit.stageMotion
import pl.dmq.peering.ui.nav.HideNavigationBar
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
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
import pl.dmq.peering.ui.wiring.rememberAppProtection
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
import pl.dmq.peering.testing.ConnectBridge

/** Where a scan goes: a Mac to pair with, or the six digits being compared on this screen. */
private enum class ScanPurpose { FindMac, ConfirmCode }

/** [depth] orders the flow (hosts, then each step toward a session); [live] marks the screen that shows video. */
private enum class ConnectStage(val fullScreen: Boolean, val depth: Int, val live: Boolean = false) {
    Scanner(true, 2), Onboarding(true, 1), Pairing(true, 1), Session(true, 3, live = true), FirstConnection(false, 0), Hosts(false, 0)
}

/** The Connect tab: first run, then the hosts, pairing, and the session a connect opened. */
@Composable
internal fun ConnectTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val active by wiring.holder.active.collectAsState()
    var onboarding by remember { mutableStateOf(!wiring.firstRun.isComplete()) }
    var pairing by remember { mutableStateOf<PairingCodePresenter?>(null) }
    var pairingSession by remember { mutableStateOf<ActiveSession?>(null) }
    var pairingHostName by remember { mutableStateOf<String?>(null) }
    val hostNames = remember { mutableMapOf<String, String>() }
    var firstConnectionDismissed by rememberSaveable { mutableStateOf(false) }
    var showingSession by rememberSaveable { mutableStateOf(false) }
    var scanning by remember { mutableStateOf<ScanPurpose?>(null) }
    val connect = remember(wiring, scope) {
        ConnectPresenter(
            hosts = wiring.discovery,
            presence = wiring.presence,
            qrSource = wiring.qrSource,
            onConnect = { hostId ->
                wiring.connectOrResume(hostId)
                showingSession = true
            },
            onConnectVia = { hostId, via ->
                wiring.connectPairedVia(hostId, via)
                showingSession = true
            },
            onPair = { hostId ->
                val session = wiring.startPairing(hostId)
                pairingHostName = hostNames[hostId]
                pairingSession = session
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
                onboarding = false
                scanning = null
                wiring.firstRun.markComplete()
            },
            onConnectAddress = { address ->
                val session = wiring.startPairingByAddress(PeerAddress(address.host, address.port))
                pairingHostName = null
                pairingSession = session
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
                onboarding = false
                wiring.firstRun.markComplete()
            },
            scope = scope,
            network = wiring.network,
            initial = wiring.lastConnectState,
        )
    }
    LaunchedEffect(wiring) {
        wiring.pendingSessionView.collect { requested ->
            if (requested) {
                showingSession = true
                wiring.pendingSessionView.value = false
            }
        }
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
    SideEffect { wiring.lastConnectState = connectState }
    connectState.listing.nearby.forEach { row -> row.name?.let { hostNames[row.id] = it } }
    val firstConnection = !firstConnectionDismissed && connectState.listing.paired.isEmpty()
    val session = active
    val presenting = pairing
    val stage = when {
        scanning != null -> ConnectStage.Scanner
        onboarding -> ConnectStage.Onboarding
        presenting != null -> ConnectStage.Pairing
        showingSession && session != null -> ConnectStage.Session
        firstConnection -> ConnectStage.FirstConnection
        else -> ConnectStage.Hosts
    }
    if (stage.fullScreen) HideNavigationBar()
    ConnectBridge(
        stage = stage.name,
        onboarding = onboarding,
        connect = connect,
        trusted = wiring.trusted,
        scope = scope,
        resetTour = { wiring.firstRun.reset(); onboarding = true },
        skipTour = { wiring.firstRun.markComplete(); onboarding = false },
        disconnect = { showingSession = false; wiring.holder.end() },
    )
    val distances = rememberMotionDistances()
    AnimatedContent(
        targetState = stage,
        modifier = Modifier.fillMaxSize(),
        transitionSpec = {
            motionTransition(stageMotion(initialState.depth, initialState.live, targetState.depth, targetState.live), distances)
        },
        label = "connectStage",
    ) { shown ->
        when (shown) {
            ConnectStage.Scanner -> QrScannerRoute(
                onCode = { text -> scanned(scanning, text, wiring.qrSource, presenting) },
                onClose = { scanning = null },
            )
            ConnectStage.Onboarding -> OnboardingRoute(
                store = wiring.firstRun,
                billing = remember(wiring) { StorePaywallBilling(wiring.billing) { context.findActivity() } },
                onFinished = { onboarding = false },
            )
            ConnectStage.Pairing -> presenting?.let { current ->
                PairingCodeRoute(
                    presenter = current,
                    onFinished = {
                        if (!current.state.value.keepsConnection && active === pairingSession) wiring.holder.end()
                        pairing = null
                    },
                    onScanRequested = { scanning = ScanPurpose.ConfirmCode },
                    hostName = pairingHostName,
                )
            }
            ConnectStage.Session -> session?.let { current ->
                SessionScreens(
                    active = current,
                    picture = wiring.picture,
                    settings = wiring.settings,
                    devicePrefs = wiring.devicePrefs,
                    macros = wiring.macros,
                    billing = wiring.billing,
                    relayAllowance = wiring.relayAllowance,
                    onClose = { showingSession = false },
                    onDisconnect = {
                        showingSession = false
                        wiring.holder.end()
                    },
                )
            }
            ConnectStage.FirstConnection -> FirstConnectionScreen(
                state = connectState,
                actions = rememberConnectActions(connect) { scanning = ScanPurpose.FindMac },
                onSkip = { firstConnectionDismissed = true },
            )
            ConnectStage.Hosts -> ConnectRoute(
                presenter = connect,
                protection = rememberAppProtection(),
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
