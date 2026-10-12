package pl.dmq.peering.ui.wiring

import androidx.activity.compose.BackHandler
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
import pl.dmq.peering.feature.terminal.TerminalRoute
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.ui.theme.PeeringColors

/** The terminal screen over the active session's shells, or a line saying there are none to offer. */
@Composable
internal fun TerminalHost(active: ActiveSession, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val sessions = active.controller.terminals
    if (sessions == null) {
        Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = stringResource(R.string.session_unavailable_terminal),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
        }
        return
    }
    val phase by active.controller.state.collectAsState()
    TerminalRoute(sessions = sessions, connected = phase.phase is SessionPhase.Ready, onBack = onBack)
}
