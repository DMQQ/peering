package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import pl.dmq.peering.ui.kit.relativeTime
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** The agents as a panel of cards over a dimmed page, rising out of the dock. A tap on the scrim closes it. */
@Composable
fun AgentPicker(
    agents: List<AgentOption>,
    usage: List<AgentUsage>,
    selectedID: String?,
    onChoose: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.55f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 84.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            agents.forEach { agent ->
                AgentHubCard(
                    agent = agent,
                    usage = usage.firstOrNull { it.agentID == agent.id },
                    isSelected = agent.id == selectedID,
                    onClick = { onChoose(agent.id) },
                )
            }
        }
    }
}

/** One agent: its tile, its name in the display face, what it is doing now, and a check circle for the selection. */
@Composable
fun AgentHubCard(agent: AgentOption, usage: AgentUsage?, isSelected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = peeringShapes.large
    val width = if (isSelected) 1.5.dp else 1.dp
    val color = if (isSelected) PeeringColors.ink.copy(alpha = 0.6f) else PeeringColors.hairline
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(PeeringColors.backdrop)
            .border(width, color, shape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = isSelected }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Box(
            Modifier.size(50.dp).background(PeeringColors.ink.copy(alpha = 0.12f), peeringShapes.extraSmall),
            contentAlignment = Alignment.Center,
        ) {
            Icon(AgentBrand.of(agent.id).icon(), contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(agent.name, style = PeeringText.display(size = 19f, tracking = -0.4f), color = PeeringColors.ink, maxLines = 1)
            UsageLine(usage)
        }
        Icon(
            if (isSelected) AgentIcons.selected else AgentIcons.unselected,
            contentDescription = null,
            tint = if (isSelected) PeeringColors.ink else PeeringColors.ink.copy(alpha = 0.25f),
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun UsageLine(usage: AgentUsage?) {
    val style = PeeringText.caption
    when {
        usage != null && usage.needsYou > 0 -> Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(AgentIcons.hand, contentDescription = null, tint = PeeringColors.caution, modifier = Modifier.size(11.dp))
            Text(stringResource(R.string.agents_waiting_on_you, usage.needsYou), style = style, color = PeeringColors.caution)
        }
        usage != null && usage.working > 0 ->
            Text(stringResource(R.string.agents_working_count, usage.working), style = style, color = PeeringColors.ink.copy(alpha = 0.85f))
        usage != null && usage.open > 0 ->
            Text(
                pluralStringResource(R.plurals.agents_open_count, usage.open, usage.open) + "  ·  " + lastUsed(usage),
                style = style,
                color = PeeringColors.muted,
            )
        else -> Text(lastUsed(usage), style = style, color = PeeringColors.muted)
    }
}

@Composable
private fun lastUsed(usage: AgentUsage?): String {
    val unix = usage?.lastUsedUnix ?: return stringResource(R.string.agents_never_used)
    val ago = LocalContext.current.resources.relativeTime(unix * 1_000L)
    return stringResource(R.string.agents_last_used, ago)
}
