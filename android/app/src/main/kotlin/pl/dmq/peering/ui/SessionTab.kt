package pl.dmq.peering.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.nav.SessionScreens
import pl.dmq.peering.ui.theme.PeeringColors

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
            clock = wiring.clock,
            onClose = null,
        )
    } else {
        Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = stringResource(R.string.sessions_none),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
        }
    }
}
