package pl.dmq.peering.ui.nav

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.agents.ComposerDraftStore
import pl.dmq.peering.feature.agents.FolderRecentsStore
import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.HubPresenter
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.HubTabBar
import pl.dmq.peering.feature.remote.HubTabsPresenter
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.kit.LocalBorderless
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.PreferencesKeyValueStore
import pl.dmq.peering.ui.wiring.TerminalHost

private const val HUB_SWAP_MS = 120

/**
 * The one full-height panel behind the terminal button: a switcher for Agents, Terminals and Files across the top, and the
 * screen of the chosen tab under it. Each tab hosts its own screen unchanged; back and the close button leave the panel.
 */
@Composable
internal fun SessionHub(
    active: ActiveSession,
    drafts: ComposerDraftStore,
    folderRecents: FolderRecentsStore,
    clock: Clock,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val preferences = remember(context) { PreferencesKeyValueStore(context.getSharedPreferences("peering_hub", Context.MODE_PRIVATE)) }
    val tabs = remember(active, preferences) {
        val offered = HubPresenter().offeredTabs(
            HubCapabilities(
                agentChat = active.controller.agentChat != null,
                fileBrowser = active.controller.files != null,
                terminal = active.controller.terminals != null,
            ),
        )
        HubTabsPresenter(offered, preferences)
    }
    BackHandler(onBack = onClose)
    CompositionLocalProvider(LocalBorderless provides true) {
        Column(Modifier.fillMaxSize().background(PeeringColors.backdrop)) {
            HubTabBar(
                offered = tabs.offered,
                selected = tabs.selected,
                onSelect = tabs::select,
                onClose = onClose,
                modifier = Modifier.windowInsetsPadding(WindowInsets.statusBars),
            )
            Box(Modifier.weight(1f).consumeWindowInsets(WindowInsets.statusBars)) {
                Crossfade(targetState = tabs.selected, animationSpec = tween(HUB_SWAP_MS), label = "hubTab") { selected ->
                    when (selected) {
                        HubTab.AGENTS -> AgentsScreen(active, drafts, folderRecents, preferences, clock, onClose)
                        HubTab.TERMINALS -> TerminalHost(active, onClose)
                        HubTab.FILES -> FilesScreen(active, onClose)
                        null -> LaunchedEffect(Unit) { onClose() }
                    }
                }
            }
        }
    }
}
