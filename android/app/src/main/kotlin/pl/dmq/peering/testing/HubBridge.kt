package pl.dmq.peering.testing

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.remote.HubChrome
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.HubTabsPresenter

/** The hub's tab and whether each tab is on its list page; the tab switch goes through the same presenter as the switcher. */
@Composable
internal fun HubBridge(tabs: HubTabsPresenter, chrome: HubChrome, onClose: () -> Unit) {
    val context = LocalContext.current
    BridgeRegistration("hub", tabs, chrome) {
        TestBridge.Slot(
            state = {
                mapOf(
                    "hubTab" to tabs.selected?.name?.lowercase(),
                    "hubOffered" to tabs.offered.map { it.name.lowercase() },
                    "hubAtRoot" to HubTab.entries.associate { it.name.lowercase() to chrome.atRoot(it) },
                )
            },
            actions = mapOf(
                "hub-close" to { onClose() },
                "hub-back" to { (context as? ComponentActivity)?.onBackPressedDispatcher?.onBackPressed() },
                "hub-tab" to { arg -> HubTab.entries.firstOrNull { it.name.equals(arg, ignoreCase = true) }?.let(tabs::select) },
            ),
        )
    }
}
