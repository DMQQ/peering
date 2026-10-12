package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.DateFormat
import java.time.ZoneId
import java.util.Date
import java.util.Locale
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * Past and elsewhere conversations as one tonal card grouped by day, a row each with the agent's tile, its title,
 * the folder, the time and a restart glyph. A conversation a terminal may still have open asks before it is taken over.
 */
@Composable
fun HistoryCard(entries: List<HistoryEntry>, onRun: (HistoryEntry) -> Unit, modifier: Modifier = Modifier) {
    var confirming by remember { mutableStateOf<HistoryEntry?>(null) }
    val groups = remember(entries) { HubHistory.group(entries, System.currentTimeMillis() / 1_000L, ZoneId.systemDefault()) }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .sessionSurface(peeringShapes.medium)
            .padding(bottom = 6.dp),
    ) {
        groups.forEachIndexed { groupIndex, group ->
            Text(
                dayLabel(group.day),
                style = PeeringText.captionSemibold.copy(fontSize = 11.5.sp),
                color = PeeringColors.ink.copy(alpha = 0.4f),
                modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = if (groupIndex == 0) 12.dp else 16.dp, bottom = 4.dp),
            )
            group.entries.forEachIndexed { index, entry ->
                if (index > 0) HorizontalDivider(modifier = Modifier.padding(start = 56.dp), color = PeeringColors.hairline)
                HistoryRow(entry) {
                    val action = entry.action
                    if (action is HistoryAction.Resume && action.openElsewhere) confirming = entry else onRun(entry)
                }
            }
        }
    }
    confirming?.let { entry ->
        PeeringAlert(
            title = stringResource(R.string.agents_open_elsewhere_title),
            message = stringResource(R.string.agents_open_elsewhere_message),
            confirm = stringResource(R.string.agents_continue_anyway),
            onConfirm = {
                confirming = null
                onRun(entry)
            },
            cancel = stringResource(R.string.agents_cancel),
            onCancel = { confirming = null },
        )
    }
}

@Composable
private fun HistoryRow(entry: HistoryEntry, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        IconTile(AgentBrand.of(entry.agentID).icon(), size = 32.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                entry.title,
                style = PeeringText.subheadlineMedium.copy(fontSize = 14.sp),
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                entry.detail,
                style = PeeringText.caption.copy(fontSize = 11.5.sp),
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                timeLabel(entry.dateUnix),
                style = PeeringText.caption.copy(fontSize = 11.5.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal),
                color = PeeringColors.ink.copy(alpha = 0.4f),
            )
            Icon(AgentIcons.restart, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.4f), modifier = Modifier.size(13.dp))
        }
    }
}

@Composable
private fun dayLabel(day: HistoryDay): String = when (day) {
    HistoryDay.Today -> stringResource(R.string.agents_day_today)
    HistoryDay.Yesterday -> stringResource(R.string.agents_day_yesterday)
    is HistoryDay.On -> day.date.format(java.time.format.DateTimeFormatter.ofPattern("MMM d", Locale.getDefault()))
}

private fun timeLabel(unixSeconds: Long): String =
    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(unixSeconds * 1_000L))
