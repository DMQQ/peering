package pl.dmq.peering.feature.sessions

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.TabScreen
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel
import pl.dmq.peering.feature.paywall.RelayAllowance

/** The Sessions tab: relay use for the day, then the recent connections. */
@Composable
fun SessionsScreen(
    records: List<SessionRecord>,
    allowance: RelayAllowance,
    nowMillis: Long,
    onUpgrade: () -> Unit,
    onOpen: (SessionRecord) -> Unit,
    modifier: Modifier = Modifier,
) {
    TabScreen(
        title = stringResource(R.string.nav_sessions),
        detail = stringResource(R.string.sessions_detail),
        modifier = modifier,
    ) {
        RelayMeter.of(allowance)?.let { meter -> RelayCard(allowance, meter, onUpgrade) }
        RecentConnectionsCard(records.take(RECENT_LIMIT), nowMillis, onOpen)
    }
}

@Composable
private fun RecentConnectionsCard(records: List<SessionRecord>, nowMillis: Long, onOpen: (SessionRecord) -> Unit) {
    Column(Modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SectionLabel(stringResource(R.string.sessions_recent), SessionIcons.history)
        if (records.isEmpty()) {
            Text(stringResource(R.string.sessions_recent_empty), style = PeeringText.caption, color = PeeringColors.tertiary, modifier = Modifier.padding(vertical = 4.dp))
        } else {
            RecentSummaryRow(RecentSummary.of(records, nowMillis))
            HorizontalDivider(color = PeeringColors.hairline)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                records.forEach { record -> RecentRow(record, nowMillis) { onOpen(record) } }
            }
        }
    }
}

@Composable
private fun RecentSummaryRow(summary: RecentSummary) {
    Row(Modifier.fillMaxWidth()) {
        SummaryValue(stringResource(R.string.sessions_summary_sessions), "${summary.sessionCount}", Modifier.weight(1f))
        SummaryValue(stringResource(R.string.sessions_summary_connected), durationLabel(summary.connectedSeconds), Modifier.weight(1f))
        SummaryValue(stringResource(R.string.sessions_summary_relay), durationLabel(summary.relaySeconds), Modifier.weight(1f))
    }
}

@Composable
private fun SummaryValue(label: String, value: String, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(value, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, maxLines = 1)
        Text(label, style = PeeringText.caption2, color = PeeringColors.tertiary)
    }
}

@Composable
private fun RecentRow(record: SessionRecord, nowMillis: Long, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().rowSurface().tappable(onClick).padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        IconTile(AppIcons.computer, size = 36.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(record.hostName, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                stringResource(R.string.sessions_row_detail, stringResource(record.path.nameRes()), durationLabel(record.durationSeconds(nowMillis))),
                style = PeeringText.caption2,
                color = PeeringColors.muted,
                maxLines = 1,
            )
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(relativeTime(record.startedAt, nowMillis), style = PeeringText.caption2, color = PeeringColors.tertiary)
            Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
        }
    }
}

private const val RECENT_LIMIT = 20
