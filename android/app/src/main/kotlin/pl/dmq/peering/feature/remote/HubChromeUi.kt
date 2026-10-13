package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp

/** The hub's chrome state, or null when a screen is shown outside the hub. */
val LocalHubChrome = staticCompositionLocalOf<HubChrome?> { null }

/** The height the switcher takes at the top of the hub, status bar included, or null outside the hub. */
val LocalHubSwitcherInset = compositionLocalOf<Dp?> { null }

/** Tells the hub whether [tab] is on its list page; a tab leaving composition counts as back on it. */
@Composable
fun ReportHubPage(tab: HubTab, atRoot: Boolean) {
    val chrome = LocalHubChrome.current ?: return
    SideEffect { chrome.setAtRoot(tab, atRoot) }
    DisposableEffect(chrome, tab) { onDispose { chrome.setAtRoot(tab, true) } }
}

/** Keeps a list page under the hub's switcher, which floats over the panel; detail pages cover it instead. */
@Composable
fun Modifier.belowHubSwitcher(): Modifier {
    val inset = LocalHubSwitcherInset.current ?: return this
    return padding(top = inset).consumeWindowInsets(WindowInsets.statusBars)
}
