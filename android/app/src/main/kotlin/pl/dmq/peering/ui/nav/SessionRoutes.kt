package pl.dmq.peering.ui.nav

import androidx.compose.animation.AnimatedContent
import pl.dmq.peering.ui.kit.modalMotion
import pl.dmq.peering.ui.kit.motionTransition
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentsRoute
import pl.dmq.peering.feature.agents.ComposerDraftStore
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.agents.FolderRecentsStore
import pl.dmq.peering.feature.files.FilesRoute
import pl.dmq.peering.feature.paywall.PaywallReason
import pl.dmq.peering.billing.PlayBilling
import pl.dmq.peering.feature.paywall.PaywallRoute
import pl.dmq.peering.feature.paywall.RelayAllowanceTracker
import pl.dmq.peering.feature.remote.MacroStore
import pl.dmq.peering.feature.remote.RemoteModel
import pl.dmq.peering.feature.remote.RemoteRoute
import pl.dmq.peering.feature.settings.DevicePreferences
import pl.dmq.peering.feature.settings.SettingsStore
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.ChatAgentsPort
import pl.dmq.peering.ui.wiring.ControllerQualityPort
import pl.dmq.peering.ui.wiring.ControllerRemoteModel
import pl.dmq.peering.ui.wiring.SessionFileBrowsing
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.TerminalHost
import pl.dmq.peering.ui.wiring.SurfacePicture
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.ui.theme.FailureNotice
import pl.dmq.peering.ui.wiring.messageRes

/** The screens a session presents over its remote screen. The hub is not one: it is its own activity. */
enum class SessionRoute { REMOTE, PAYWALL }

/**
 * The session's screens, one at a time. Back returns to the remote screen from the others. [onClose] leaves the screen
 * with the session still running; [onDisconnect] runs when the user ends the session.
 */
@Composable
internal fun SessionScreens(
    active: ActiveSession,
    picture: SurfacePicture,
    settings: SettingsStore,
    devicePrefs: DevicePreferences,
    macros: MacroStore,
    billing: PlayBilling,
    relayAllowance: RelayAllowanceTracker,
    onClose: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var route by rememberSaveable { mutableStateOf(SessionRoute.REMOTE) }
    var spentPaywall by rememberSaveable { mutableStateOf(false) }
    val remote = remember(active) {
        ControllerRemoteModel(
            controller = active.controller,
            picture = picture,
            scope = scope,
            quality = ControllerQualityPort(active.controller, settings, scope),
            prefs = devicePrefs,
            macros = macros,
            relayAllowance = relayAllowance.allowance,
            onDisconnect = onDisconnect,
            onLeave = onClose,
            onOpenHub = { context.startActivity(Intent(context, HubActivity::class.java)) },
            onOpenPaywall = { route = SessionRoute.PAYWALL },
        )
    }
    val session by active.controller.state.collectAsState()
    val browser = active.controller.files
    LaunchedEffect(browser) { browser?.let { active.downloads.watch(it) } }
    LaunchedEffect(session.phase) {
        val phase = session.phase
        if (phase is SessionPhase.Failed && phase.reason == SessionFailure.Quota) {
            relayAllowance.relayRefusedQuota()
            spentPaywall = true
            route = SessionRoute.PAYWALL
        }
    }
    BackHandler(enabled = route != SessionRoute.REMOTE) { route = SessionRoute.REMOTE }
    AnimatedContent(
        targetState = route,
        transitionSpec = {
            motionTransition(modalMotion(initialState != SessionRoute.REMOTE, targetState != SessionRoute.REMOTE), 0)
        },
        label = "sessionRoute",
    ) { shown ->
        when (shown) {
            SessionRoute.REMOTE -> RemoteWithNotice(remote, session.phase)
            SessionRoute.PAYWALL -> PaywallRoute(
                billing = StorePaywallBilling(billing) { context.findActivity() },
                allowance = relayAllowance.allowance,
                reason = if (spentPaywall) PaywallReason.RelayTimeSpent else PaywallReason.Upgrade,
                startsWithAllowanceNotice = false,
                onDismiss = { route = SessionRoute.REMOTE },
            )
        }
    }
}

@Composable
private fun RemoteWithNotice(remote: RemoteModel, phase: SessionPhase) {
    RemoteRoute(remote)
    val notice = when (phase) {
        is SessionPhase.Failed -> stringResource(phase.reason.messageRes())
        SessionPhase.Ended -> stringResource(R.string.session_ended)
        else -> null
    }
    val details = (phase as? SessionPhase.Failed)?.reason?.cause
    if (notice != null) {
        Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.Bottom,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            FailureNotice(message = notice, details = details)
        }
    }
}

@Composable
internal fun AgentsScreen(
    active: ActiveSession,
    drafts: ComposerDraftStore,
    folderRecents: FolderRecentsStore,
    guideStore: KeyValueStore,
    clock: Clock,
) {
    val chat = active.controller.agentChat
    if (chat == null) {
        Unavailable(R.string.session_unavailable_agents)
        return
    }
    AgentsRoute(
        port = remember(chat) { ChatAgentsPort(chat) },
        recents = remember(folderRecents, active.target.hostId) {
            FolderRecents(folderRecents, active.target.hostId.orEmpty())
        },
        declaredAgentIDs = active.controller.declaredAgentIDs,
        chatSupported = true,
        modelPickerSupported = chat.capabilities.modelPicker,
        draftStore = drafts,
        guideStore = guideStore,
        clock = clock,
    )
}

@Composable
internal fun FilesScreen(active: ActiveSession, onBack: () -> Unit, hosted: Boolean = false) {
    val browser = active.controller.files
    if (browser == null) {
        Unavailable(R.string.session_unavailable_files)
        return
    }
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
    val port = remember(browser) {
        val online = active.controller.state.map { it.phase is SessionPhase.Ready }
            .stateIn(scope, SharingStarted.Eagerly, active.controller.state.value.phase is SessionPhase.Ready)
        SessionFileBrowsing(browser, active.downloads, resolver, online, scope)
    }
    FilesRoute(port = port, onBack = onBack, hosted = hosted)
}

@Composable
private fun Unavailable(textRes: Int) {
    Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text = stringResource(textRes), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
    }
}
