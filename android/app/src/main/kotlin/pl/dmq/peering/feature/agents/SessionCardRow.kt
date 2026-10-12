package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun SessionCardRow(
    card: SessionCard,
    onOpen: () -> Unit,
    onEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedPanel(
        modifier = modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.large)
            .clickable(onClick = onOpen),
    ) {
        Text(card.title, style = MaterialTheme.typography.titleMedium, color = PeeringColors.ink, maxLines = 1)
        Text(card.directory, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, maxLines = 1)
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stateLabel(card.state), style = MaterialTheme.typography.labelMedium, color = stateColor(card.state))
            if (card.pendingApprovals > 0) {
                Text(
                    pluralStringResource(R.plurals.agents_pending_approvals, card.pendingApprovals, card.pendingApprovals),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.caution,
                )
            }
            Text(
                lastActivityLabel(card.lastActivityUnix),
                style = MaterialTheme.typography.labelMedium,
                color = PeeringColors.faint,
            )
        }
        if (card.state != SessionCardState.ENDED) {
            TextButton(onClick = onEnd, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(R.string.agents_end_chat), style = MaterialTheme.typography.labelLarge, color = PeeringColors.muted)
            }
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
    },
)

private fun stateColor(state: SessionCardState) = when (state) {
    SessionCardState.NEEDS_YOU -> PeeringColors.caution
    SessionCardState.FAILED -> PeeringColors.danger
    SessionCardState.WORKING -> PeeringColors.ink
    SessionCardState.IDLE, SessionCardState.ENDED -> PeeringColors.muted
}

@Composable
private fun lastActivityLabel(unixSeconds: Long): String {
    val now = System.currentTimeMillis() / 1_000L
    return when (val age = RelativeAge.between(now, unixSeconds)) {
        RelativeAge.JustNow -> stringResource(R.string.agents_active_just_now)
        is RelativeAge.Minutes -> pluralStringResource(R.plurals.agents_active_minutes, age.count, age.count)
        is RelativeAge.Hours -> pluralStringResource(R.plurals.agents_active_hours, age.count, age.count)
        is RelativeAge.Days -> pluralStringResource(R.plurals.agents_active_days, age.count, age.count)
    }
}
