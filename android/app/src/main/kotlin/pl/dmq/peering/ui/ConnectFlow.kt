package pl.dmq.peering.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.feature.pairing.PairingCodePresenter
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.ControllerPairingSession

/** Where a scan goes: a Mac to pair with, or the six digits being compared on this screen. */
internal enum class ScanPurpose { FindMac, ConfirmCode }

/** [depth] orders the flow (hosts, then each step toward a session); [live] marks the screen that shows video. */
internal enum class ConnectStage(val fullScreen: Boolean, val depth: Int, val live: Boolean = false) {
    Scanner(true, 2), Onboarding(true, 1), Pairing(true, 1), Session(true, 3, live = true), FirstConnection(false, 0), Hosts(false, 0)
}

/** What the Connect tab is showing and the pairing it is in the middle of. */
@Stable
internal class ConnectFlow(onboarding: Boolean, showingSession: Boolean = false, firstConnectionDismissed: Boolean = false) {
    var onboarding by mutableStateOf(onboarding)
    var showingSession by mutableStateOf(showingSession)
    var firstConnectionDismissed by mutableStateOf(firstConnectionDismissed)
    var scanning by mutableStateOf<ScanPurpose?>(null)
    var pairing by mutableStateOf<PairingCodePresenter?>(null)
    var pairingSession by mutableStateOf<ActiveSession?>(null)
    var pairingHostName by mutableStateOf<String?>(null)
    var pairingInline by mutableStateOf(false)
    val hostNames = mutableMapOf<String, String>()

    fun beginPairing(wiring: FeatureWiring, scope: CoroutineScope, session: ActiveSession, hostName: String?) {
        pairingHostName = hostName
        pairingInline = !firstConnectionDismissed && (wiring.lastConnectState?.listing?.paired?.isEmpty() ?: true)
        pairingSession = session
        pairing = PairingCodePresenter(ControllerPairingSession(session.controller, scope), scope)
        onboarding = false
        wiring.firstRun.markComplete()
    }

    fun stage(firstConnection: Boolean, session: ActiveSession?): ConnectStage = when {
        scanning != null -> ConnectStage.Scanner
        onboarding -> ConnectStage.Onboarding
        pairing != null && pairingInline -> ConnectStage.FirstConnection
        pairing != null -> ConnectStage.Pairing
        showingSession && session != null -> ConnectStage.Session
        firstConnection -> ConnectStage.FirstConnection
        else -> ConnectStage.Hosts
    }
}

@Composable
internal fun rememberConnectFlow(wiring: FeatureWiring): ConnectFlow {
    val saver = Saver<ConnectFlow, List<Boolean>>(
        save = { listOf(it.showingSession, it.firstConnectionDismissed) },
        restore = { ConnectFlow(onboarding = !wiring.firstRun.isComplete(), showingSession = it[0], firstConnectionDismissed = it[1]) },
    )
    return rememberSaveable(saver = saver) { ConnectFlow(onboarding = !wiring.firstRun.isComplete()) }
}
