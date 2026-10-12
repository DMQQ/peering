package pl.dmq.peering.ui.wiring

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.files.FileBrowser

/** The file screens' view of [browser], online while the session is ready. The Files tab and the folder pickers share it. */
@Composable
internal fun rememberFileBrowsing(active: ActiveSession, browser: FileBrowser): FileBrowsingPort {
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
    return remember(browser) {
        val online = active.controller.state.map { it.phase is SessionPhase.Ready }
            .stateIn(scope, SharingStarted.Eagerly, active.controller.state.value.phase is SessionPhase.Ready)
        SessionFileBrowsing(browser, active.downloads, resolver, online, scope)
    }
}
