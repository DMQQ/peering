package pl.dmq.peering.ui.nav

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.agents.ComposerDraftStore
import pl.dmq.peering.feature.agents.FolderRecentsStore
import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.HubChrome
import pl.dmq.peering.feature.remote.HubPresenter
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.HubTabBar
import pl.dmq.peering.feature.remote.HubTabBarHeight
import pl.dmq.peering.feature.remote.HubTabsPresenter
import pl.dmq.peering.feature.remote.LocalHubChrome
import pl.dmq.peering.feature.remote.LocalHubSwitcherInset
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.kit.LocalBorderless
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.wiring.ActiveSession
import pl.dmq.peering.ui.wiring.PreferencesKeyValueStore
import pl.dmq.peering.ui.wiring.TerminalHost

private const val HUB_SWAP_MS = 120
private const val SWITCHER_MS = 160

/**
 * The one full-height panel behind the terminal button: a switcher for Agents, Terminals and Files floating over the top of the list pages, and the
 * screen of the chosen tab. A detail page covers the whole panel and the switcher steps away. Each tab hosts its own screen unchanged; back and the close button leave the panel.
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
    val chrome = remember { HubChrome() }
    val density = LocalDensity.current
    val switcherInset = with(density) { WindowInsets.statusBars.getTop(density).toDp() } + HubTabBarHeight
    BackHandler(onBack = onClose)
    CompositionLocalProvider(
        LocalBorderless provides true,
        LocalHubChrome provides chrome,
        LocalHubSwitcherInset provides switcherInset,
    ) {
        Box(Modifier.fillMaxSize().background(PeeringColors.backdrop)) {
            Crossfade(targetState = tabs.selected, animationSpec = tween(HUB_SWAP_MS), label = "hubTab") { selected ->
                when (selected) {
                    HubTab.AGENTS -> AgentsScreen(active, drafts, folderRecents, preferences, clock, onClose)
                    HubTab.TERMINALS -> TerminalHost(
                        active,
                        preferences,
                        onFiles = if (HubTab.FILES in tabs.offered) ({ tabs.select(HubTab.FILES) }) else null,
                        onBack = onClose,
                    )
                    HubTab.FILES -> FilesScreen(active, onClose, hosted = true)
                    null -> LaunchedEffect(Unit) { onClose() }
                }
            }
            AnimatedVisibility(
                visible = chrome.showsSwitcher(tabs.selected),
                modifier = Modifier.align(Alignment.TopCenter),
                enter = fadeIn(tween(SWITCHER_MS)) + slideInVertically(tween(SWITCHER_MS)) { -it },
                exit = fadeOut(tween(SWITCHER_MS)) + slideOutVertically(tween(SWITCHER_MS)) { -it },
            ) {
                HubTabBar(
                    offered = tabs.offered,
                    selected = tabs.selected,
                    onSelect = tabs::select,
                    onClose = onClose,
                    modifier = Modifier.windowInsetsPadding(WindowInsets.statusBars),
                )
            }
        }
    }
}
