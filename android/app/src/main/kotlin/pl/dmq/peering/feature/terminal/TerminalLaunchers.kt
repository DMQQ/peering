package pl.dmq.peering.feature.terminal

import pl.dmq.peering.ui.kit.tonalCard
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

private val CardRadius = peeringShapes.medium
private val HistoryRadius = peeringShapes.medium

private fun TerminalAgent.icon(): ImageVector = when (id) {
    "claude" -> AppIcons.sparkles
    "codex" -> AppIcons.code
    "opencode" -> TerminalGlyphs.curlyBraces
    "hermes" -> TerminalGlyphs.paperPlane
    "gemini" -> TerminalGlyphs.diamond
    else -> TerminalGlyphs.wand
}

@Composable
private fun LaunchAge.text(): String = when (this) {
    LaunchAge.JustNow -> stringResource(R.string.terminal_age_now)
    is LaunchAge.Minutes -> pluralStringResource(R.plurals.terminal_age_minutes, count, count)
    is LaunchAge.Hours -> pluralStringResource(R.plurals.terminal_age_hours, count, count)
    LaunchAge.Yesterday -> stringResource(R.string.terminal_age_yesterday)
    is LaunchAge.Days -> pluralStringResource(R.plurals.terminal_age_days, count, count)
    LaunchAge.LastWeek -> stringResource(R.string.terminal_age_last_week)
    is LaunchAge.Weeks -> pluralStringResource(R.plurals.terminal_age_weeks, count, count)
    LaunchAge.LastMonth -> stringResource(R.string.terminal_age_last_month)
    is LaunchAge.Months -> pluralStringResource(R.plurals.terminal_age_months, count, count)
}

/** An agent's tile, its name and when it was last started here, with an outlined Start. */
@Composable
fun LauncherCardRow(card: LauncherCard, enabled: Boolean, onStart: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().tonalCard(CardRadius).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        IconTile(card.agent.icon(), size = 50.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                card.agent.name,
                style = PeeringText.display(size = 19f, tracking = -0.4f),
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                card.lastUsed?.let { stringResource(R.string.terminal_launch_last_used, it.text()) }
                    ?: stringResource(R.string.terminal_launch_never),
                style = PeeringText.caption,
                color = PeeringColors.muted,
                maxLines = 1,
            )
        }
        Box(
            Modifier
                .railPress(onStart, enabled = enabled, scale = 0.96f)
                .clip(PillShape)
                .border(1.dp, PeeringColors.outline, PillShape)
                .padding(horizontal = 18.dp, vertical = 9.dp),
        ) {
            Text(
                stringResource(R.string.terminal_launch_start),
                style = PeeringText.subheadlineSemibold.copy(fontSize = 15.sp),
                color = PeeringColors.ink.copy(alpha = if (enabled) 1f else 0.4f),
            )
        }
    }
}

/** The serif heading with Clear history at its end. */
@Composable
fun LaunchHistoryHeading(onClear: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 12.dp), verticalAlignment = Alignment.Bottom) {
        Text(
            stringResource(R.string.terminal_launch_history),
            style = PeeringText.display(size = 28f, tracking = -0.6f),
            color = PeeringColors.ink,
            modifier = Modifier.weight(1f),
        )
        Text(
            stringResource(R.string.terminal_launch_clear),
            style = PeeringText.caption.copy(fontWeight = FontWeight.Medium, fontSize = 13.sp),
            color = PeeringColors.muted,
            modifier = Modifier.clickable(onClick = onClear).padding(vertical = 6.dp),
        )
    }
}

/** Past starts as one outlined card, a row each: the agent, the computer, and how long ago. A tap starts it again. */
@Composable
fun LaunchHistoryCard(rows: List<HistoryRow>, onRestart: (HistoryRow) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().tonalCard(HistoryRadius)) {
        rows.forEachIndexed { index, row ->
            if (index > 0) Box(Modifier.fillMaxWidth().padding(start = 14.dp).height(1.dp).background(PeeringColors.hairline))
            Row(
                Modifier.fillMaxWidth().clickable { onRestart(row) }.padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(row.title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (row.computer.isNotEmpty()) {
                        Text(row.computer, style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Text(row.age.text(), style = PeeringText.caption.copy(fontSize = 13.sp), color = PeeringColors.muted, maxLines = 1)
            }
        }
    }
}
