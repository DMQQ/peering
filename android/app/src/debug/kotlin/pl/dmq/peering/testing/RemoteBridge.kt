package pl.dmq.peering.testing

import android.util.Log
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.pager.PagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.remote.ClipboardPort
import pl.dmq.peering.feature.remote.RemoteActions
import pl.dmq.peering.feature.remote.SessionPanel
import pl.dmq.peering.feature.remote.SessionScreenState
import pl.dmq.peering.feature.remote.StatusPillPresenter

private val panels = mapOf(
    "apps" to SessionPanel.SOURCES,
    "clipboard" to SessionPanel.CLIPBOARD,
    "shortcuts" to SessionPanel.SHORTCUTS,
    "settings" to SessionPanel.SETTINGS,
)

/** The remote screen's panels, pill, dock, immersive and keyboard flags, driven through the screen state the buttons write to. */
@Composable
internal fun RemoteBridge(screen: SessionScreenState, pill: StatusPillPresenter, actions: RemoteActions, clipboard: ClipboardPort) {
    BridgeRegistration("remote", screen, pill, actions, clipboard) {
        TestBridge.Slot(
            state = {
                mapOf(
                    "openPanel" to (panels.entries.firstOrNull { it.value == screen.openPanel }?.key ?: "none"),
                    "pillExpanded" to pill.expanded,
                    "dockExpanded" to screen.dockExpanded,
                    "immersive" to screen.immersive,
                    "keyboardShown" to screen.keyboardShown,
                    "clipboardHistory" to clipboard.history.value.size,
                )
            },
            actions = mapOf(
                "panel" to { arg -> panel(screen, arg) },
                "pill" to { arg -> if (pill.expanded != (arg == "open")) pill.onTap() },
                "dock" to { arg -> screen.dockExpanded = arg == "expand" },
                "clipboard-send" to { arg -> arg?.let(actions::send) },
                "clipboard-history" to { Log.i("PEERTEST", "clipboardHistory size=" + clipboard.history.value.size) },
            ),
        )
    }
}

private fun panel(screen: SessionScreenState, arg: String?) {
    when (arg) {
        "close" -> {
            screen.closePanel()
            screen.hideKeyboard()
        }
        "keyboard" -> if (!screen.keyboardShown) screen.toggleKeyboard()
        else -> panels[arg]?.let(screen::showPanel)
    }
}

/** The dock's page, which only the collapsed dock has; "dock-page" scrolls it the way a swipe would. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DockBridge(state: PagerState) {
    val scope = rememberCoroutineScope()
    BridgeRegistration("dock", state) {
        TestBridge.Slot(
            state = { mapOf("dockPage" to state.currentPage, "dockPages" to state.pageCount) },
            actions = mapOf(
                "dock-page" to { arg -> arg?.toIntOrNull()?.let { scope.launch { state.animateScrollToPage(it.coerceIn(0, state.pageCount - 1)) } } },
            ),
        )
    }
}
