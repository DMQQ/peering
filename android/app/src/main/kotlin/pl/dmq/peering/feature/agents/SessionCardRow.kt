package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** One chat as an outlined card: who and where, what it is doing, and a menu to stop or close it. */
@Composable
fun SessionCardRow(
    card: SessionCard,
    onOpen: () -> Unit,
    onPause: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedPanel(
        modifier = modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.large)
            .clickable(onClick = onOpen),
        contentPadding = PaddingValues(start = 16.dp, top = 8.dp, bottom = 12.dp, end = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(card.title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
                Text(
                    "${card.agentName}  ·  ${card.directory}",
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.muted,
                    maxLines = 1,
                )
            }
            CardMenu(card, onPause, onClose)
        }
        Row(
            modifier = Modifier.padding(end = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(stateLabel(card.state), style = MaterialTheme.typography.labelMedium, color = stateColor(card.state))
            if (card.pendingApprovals > 0) {
                Text(
                    pluralStringResource(R.plurals.agents_pending_approvals, card.pendingApprovals, card.pendingApprovals),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.caution,
                )
            }
            Text(lastActivityLabel(card.lastActivityUnix), style = MaterialTheme.typography.labelMedium, color = PeeringColors.faint)
        }
    }
}

@Composable
private fun CardMenu(card: SessionCard, onPause: () -> Unit, onClose: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.size(48.dp)) {
            Icon(AppIcons.more, contentDescription = stringResource(R.string.agents_chat_options), tint = PeeringColors.muted)
        }
        PeeringMenu(open, { open = false }) {
            if (card.canPause) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_stop_to_history),
                    onClick = {
                        open = false
                        onPause()
                    },
                )
            }
            PeeringMenuItem(
                title = stringResource(R.string.agents_end_chat),
                destructive = true,
                onClick = {
                    open = false
                    onClose()
                },
            )
        }
    }
}

@Composable
private fun stateLabel(state: SessionCardState): String = stringResource(
    when (state) {
        SessionCardState.WORKING -> R.string.agents_state_working
        SessionCardState.NEEDS_YOU -> R.string.agents_state_needs_you
        SessionCardState.IDLE -> R.string.agents_state_idle
        SessionCardState.ENDED -> R.string.agents_state_ended
        SessionCardState.FAILED -> R.string.agents_state_failed
        SessionCardState.PAUSED -> R.string.agents_state_paused
    },
)

private fun stateColor(state: SessionCardState) = when (state) {
    SessionCardState.NEEDS_YOU -> PeeringColors.caution
    SessionCardState.FAILED -> PeeringColors.danger
    SessionCardState.WORKING -> PeeringColors.ink
    SessionCardState.IDLE, SessionCardState.ENDED, SessionCardState.PAUSED -> PeeringColors.muted
}

@Composable
internal fun lastActivityLabel(unixSeconds: Long): String {
    val now = System.currentTimeMillis() / 1_000L
    return when (val age = RelativeAge.between(now, unixSeconds)) {
        RelativeAge.JustNow -> stringResource(R.string.agents_active_just_now)
        is RelativeAge.Minutes -> pluralStringResource(R.plurals.agents_active_minutes, age.count, age.count)
        is RelativeAge.Hours -> pluralStringResource(R.plurals.agents_active_hours, age.count, age.count)
        is RelativeAge.Days -> pluralStringResource(R.plurals.agents_active_days, age.count, age.count)
    }
}
