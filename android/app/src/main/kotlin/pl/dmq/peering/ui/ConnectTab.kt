package pl.dmq.peering.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.feature.connect.ConnectPresenter
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.testing.ConnectBridge
import pl.dmq.peering.ui.kit.motionTransition
import pl.dmq.peering.ui.kit.rememberMotionDistances
import pl.dmq.peering.ui.kit.stageMotion
import pl.dmq.peering.ui.nav.HideNavigationBar
import pl.dmq.peering.ui.wiring.ActiveSession

/** The Connect tab: first run, then the hosts, pairing, and the session a connect opened. */
@Composable
internal fun ConnectTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val active by wiring.holder.active.collectAsState()
    val flow = rememberConnectFlow(wiring)
    val connect = rememberConnectPresenter(wiring, scope, flow)
    ConnectEffects(wiring, flow, active)
    val connectState by connect.state.collectAsState()
    SideEffect { wiring.lastConnectState = connectState }
    connectState.listing.nearby.forEach { row -> row.name?.let { flow.hostNames[row.id] = it } }
    val firstConnection = !flow.firstConnectionDismissed && connectState.listing.paired.isEmpty()
    val session = active
    val presenting = flow.pairing
    val stage = flow.stage(firstConnection, session)
    if (stage.fullScreen || presenting != null) HideNavigationBar()
    ConnectBridge(
        stage = stage.name,
        onboarding = flow.onboarding,
        connect = connect,
        trusted = wiring.trusted,
        scope = scope,
        resetTour = { wiring.firstRun.reset(); flow.onboarding = true },
        skipTour = { wiring.firstRun.markComplete(); flow.onboarding = false },
        disconnect = { flow.showingSession = false; wiring.holder.end() },
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
        ConnectStageContent(shown, wiring, flow, connect, connectState, presenting, session)
    }
}

@Composable
private fun rememberConnectPresenter(wiring: FeatureWiring, scope: CoroutineScope, flow: ConnectFlow): ConnectPresenter =
    remember(wiring, scope) {
        ConnectPresenter(
            hosts = wiring.discovery,
            presence = wiring.presence,
            qrSource = wiring.qrSource,
            onConnect = { hostId ->
                wiring.connectOrResume(hostId)
                flow.showingSession = true
            },
            onConnectVia = { hostId, via ->
                wiring.connectPairedVia(hostId, via)
                flow.showingSession = true
            },
            onPair = { hostId ->
                flow.beginPairing(wiring, scope, wiring.startPairing(hostId), flow.hostNames[hostId])
                flow.scanning = null
            },
            onWake = { hostId -> wiring.wakeHost(hostId) },
            onConnectAddress = { address ->
                flow.beginPairing(wiring, scope, wiring.startPairingByAddress(PeerAddress(address.host, address.port)), null)
            },
            scope = scope,
            network = wiring.network,
            initial = wiring.lastConnectState,
        )
    }

@Composable
private fun ConnectEffects(wiring: FeatureWiring, flow: ConnectFlow, active: ActiveSession?) {
    LaunchedEffect(wiring) {
        wiring.pendingSessionView.collect { requested ->
            if (requested) {
                flow.showingSession = true
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
        if (flow.pairing != null && active !== flow.pairingSession) flow.pairing = null
    }
}
