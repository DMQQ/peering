package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ReadableWidth
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.kit.CardShape
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop

/** Asks how to use the computer that just connected. [current] is the mode in use, marked with the state blue. */
@Composable
fun ModePicker(
    available: List<SessionMode>,
    current: SessionMode?,
    hostName: String?,
    onPick: (SessionMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    ReadableWidth(modifier.peeringBackdrop(), max = 560.dp) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        ) {
            Text(stringResource(R.string.mode_picker_title), style = PeeringText.display(size = 30f, tracking = -1f), color = PeeringColors.ink)
            hostName?.let { Text(it, style = PeeringText.subheadline, color = PeeringColors.muted) }
            available.forEach { mode -> ModeCard(mode, selected = mode == current, onClick = { onPick(mode) }) }
        }
    }
}

@Composable
private fun ModeCard(mode: SessionMode, selected: Boolean, onClick: () -> Unit) {
    OutlinedPanel(Modifier.fillMaxWidth().clip(CardShape).tappable(onClick)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Icon(mode.icon(), contentDescription = null, tint = if (selected) PeeringColors.accent else PeeringColors.ink, modifier = Modifier.size(28.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(mode.titleRes()), style = PeeringText.headline, color = PeeringColors.ink)
                Text(stringResource(mode.bodyRes()), style = PeeringText.subheadline, color = PeeringColors.muted)
            }
        }
    }
}

private fun SessionMode.icon(): ImageVector = when (this) {
    SessionMode.SCREEN -> AppIcons.fit
    SessionMode.WORKSPACE -> SessionIcons.terminal
    SessionMode.REMOTE -> SessionIcons.hand
}

private fun SessionMode.titleRes(): Int = when (this) {
    SessionMode.SCREEN -> R.string.mode_screen_title
    SessionMode.WORKSPACE -> R.string.mode_workspace_title
    SessionMode.REMOTE -> R.string.mode_remote_title
}

private fun SessionMode.bodyRes(): Int = when (this) {
    SessionMode.SCREEN -> R.string.mode_screen_body
    SessionMode.WORKSPACE -> R.string.mode_workspace_body
    SessionMode.REMOTE -> R.string.mode_remote_body
}
