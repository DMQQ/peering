package pl.dmq.peering.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.TitleBarScreen
import pl.dmq.peering.ui.nav.SessionScreens
import pl.dmq.peering.ui.theme.EmptyState

/** The Sessions tab: the session in progress, or a line saying there is none. */
@Composable
internal fun SessionTab(wiring: FeatureWiring) {
    val active by wiring.holder.active.collectAsState()
    val session = active
    if (session != null) {
        SessionScreens(
            active = session,
            picture = wiring.picture,
            drafts = wiring.drafts,
            folderRecents = wiring.folderRecents,
            settings = wiring.settings,
            billing = wiring.billing,
            relayAllowance = wiring.relayAllowance,
            clock = wiring.clock,
            onClose = null,
            onDisconnect = wiring.holder::end,
        )
    } else {
        TitleBarScreen(title = stringResource(R.string.nav_sessions), scrollable = false) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth().padding(bottom = 48.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = null,
                    mascot = true,
                    title = stringResource(R.string.sessions_none_title),
                    body = stringResource(R.string.sessions_none),
                )
            }
        }
    }
}
