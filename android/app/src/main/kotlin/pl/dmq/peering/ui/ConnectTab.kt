package pl.dmq.peering.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
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
import pl.dmq.peering.ui.wiring.ControllerPairingSession
import pl.dmq.peering.ui.wiring.NoCameraQrSource
import pl.dmq.peering.ui.nav.SessionScreens

/** The Connect tab: first run, then the hosts, pairing, and the session a connect opened. */
@Composable
internal fun ConnectTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val active by wiring.holder.active.collectAsState()
    var onboarding by remember { mutableStateOf(!wiring.firstRun.isComplete()) }
    var pairing by remember { mutableStateOf<PairingCodePresenter?>(null) }
    var showingSession by rememberSaveable { mutableStateOf(false) }
    val connect = remember(wiring, scope) {
        ConnectPresenter(
            hosts = wiring.discovery,
            presence = wiring.presence,
            qrSource = NoCameraQrSource,
            onConnect = { hostId ->
                wiring.connectPaired(hostId)
                showingSession = true
            },
            onPair = { hostId ->
                val session = wiring.startPairing(hostId)
                pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
            },
            scope = scope,
        )
    }
    val session = active
    val presenting = pairing
    Box(modifier = Modifier.fillMaxSize()) {
        when {
            onboarding -> OnboardingRoute(
                store = wiring.firstRun,
                onScanPairingCode = {},
                onFinished = { onboarding = false },
            )
            presenting != null -> PairingCodeRoute(
                presenter = presenting,
                onFinished = { pairing = null },
            )
            showingSession && session != null -> SessionScreens(
                active = session,
                picture = wiring.picture,
                drafts = wiring.drafts,
                clock = wiring.clock,
                onClose = { showingSession = false },
            )
            else -> ConnectRoute(presenter = connect)
        }
    }
}
