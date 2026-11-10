package pl.dmq.peering.ui.nav

import androidx.activity.OnBackPressedDispatcher
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import pl.dmq.peering.feature.remote.HubTab

/**
 * The hub's tabs as pages that stay composed, so switching shows a page that is already built instead of rebuilding its
 * presenters and asking the computer again. Swiping is off: the terminal and the chat own horizontal drags.
 */
@Composable
internal fun HubPager(tabs: List<HubTab>, selected: HubTab, modifier: Modifier = Modifier, page: @Composable (HubTab) -> Unit) {
    val pager = rememberPagerState(initialPage = tabs.indexOf(selected).coerceAtLeast(0)) { tabs.size }
    val focus = LocalFocusManager.current
    LaunchedEffect(selected, tabs) {
        val index = tabs.indexOf(selected)
        if (index >= 0 && index != pager.currentPage) {
            focus.clearFocus()
            pager.scrollToPage(index)
        }
    }
    val detached = rememberDetachedBackOwner()
    val attached = LocalOnBackPressedDispatcherOwner.current
    HorizontalPager(
        state = pager,
        modifier = modifier.fillMaxSize(),
        userScrollEnabled = false,
        beyondViewportPageCount = tabs.size,
        key = { index -> tabs[index] },
    ) { index ->
        val tab = tabs[index]
        // A page out of sight keeps its back handlers registered, and the last one registered wins; this one would take back
        // from the page on screen. Off screen they register with a dispatcher nothing presses.
        val owner = if (tab == selected || attached == null) attached else detached
        if (owner == null) {
            page(tab)
        } else {
            CompositionLocalProvider(LocalOnBackPressedDispatcherOwner provides owner) { page(tab) }
        }
    }
}

@Composable
private fun rememberDetachedBackOwner(): OnBackPressedDispatcherOwner {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return remember(lifecycle) {
        object : OnBackPressedDispatcherOwner {
            override val onBackPressedDispatcher = OnBackPressedDispatcher()
            override val lifecycle: Lifecycle = lifecycle
        }
    }
}
