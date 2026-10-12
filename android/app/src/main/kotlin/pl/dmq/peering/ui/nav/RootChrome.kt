package pl.dmq.peering.ui.nav

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/** Whether the root navigation bar shows: full-screen flows (the tour, the scanner, a live session) ask it to step aside. */
@Stable
class RootChrome {
    private var hiders by mutableIntStateOf(0)
    val navigationBarVisible: Boolean get() = hiders == 0

    internal fun hide() { hiders++ }
    internal fun show() { hiders-- }
}

val LocalRootChrome = compositionLocalOf { RootChrome() }

/** Hides the root navigation bar for as long as this is in the composition. */
@Composable
fun HideNavigationBar() {
    val chrome = LocalRootChrome.current
    DisposableEffect(chrome) {
        chrome.hide()
        onDispose { chrome.show() }
    }
}
