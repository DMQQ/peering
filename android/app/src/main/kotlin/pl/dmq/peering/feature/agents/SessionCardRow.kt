package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * One chat as the iPhone draws it: the agent's tile, the title, a state pill with the folder beside it, and the
 * latest reply underneath. A long press offers a new chat here, stopping it to history, and closing it.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionCardRow(
    card: SessionCard,
    onOpen: () -> Unit,
    onNewChatHere: () -> Unit,
    onPause: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Box(modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(peeringShapes.medium)
                .border(1.dp, PeeringColors.hairline, peeringShapes.medium)
                .combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true })
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(if (card.preview != null) 10.dp else 0.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTile(AgentBrand.of(card.agentID).icon(), size = 42.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(
                        card.title,
                        style = PeeringText.subheadlineSemibold.copy(fontSize = 15.5.sp),
                        color = PeeringColors.ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                        StatePill(card.state)
                        FolderAndAgent(card)
                    }
                }
            }
            card.preview?.let { Preview(it) }
        }
        PeeringMenu(menuOpen, { menuOpen = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.agents_new_chat_here),
                icon = AgentIcons.plus,
                onClick = {
                    menuOpen = false
                    onNewChatHere()
                },
            )
            if (card.canPause) {
                PeeringMenuItem(
                    title = stringResource(R.string.agents_stop_to_history),
                    icon = AgentIcons.archive,
                    destructive = true,
                    onClick = {
                        menuOpen = false
                        onPause()
                    },
                )
            }
            PeeringMenuItem(
                title = stringResource(R.string.agents_close_chat),
                icon = AppIcons.close,
                destructive = true,
                onClick = {
                    menuOpen = false
                    onClose()
                },
            )
        }
    }
}

@Composable
private fun FolderAndAgent(card: SessionCard) {
    val folder = card.directory.trimEnd('/').substringAfterLast('/')
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (folder.isNotEmpty()) {
            Icon(AppIcons.folder, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(11.dp))
            Text(
                folder,
                style = PeeringText.caption.copy(fontSize = 11.5.sp, fontFamily = FontFamily.Monospace),
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
        if (!card.title.contains(card.agentName, ignoreCase = true)) {
            Text(card.agentName, style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1)
        }
    }
}

@Composable
private fun Preview(text: String) {
    Text(
        text,
        style = PeeringText.footnote.copy(fontSize = 13.sp),
        color = PeeringColors.ink.copy(alpha = 0.62f),
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .clip(peeringShapes.extraSmall)
            .background(PeeringColors.surface)
            .padding(horizontal = 11.dp, vertical = 8.dp),
    )
}

/** Outlined and tinted: the caution hue for a chat waiting on you, the danger hue for a failure, white shades otherwise. */
@Composable
private fun StatePill(state: SessionCardState) {
    val tint = stateColor(state)
    Row(
        modifier = Modifier
            .clip(PillShape)
            .border(1.dp, tint.copy(alpha = 0.35f), PillShape)
            .padding(horizontal = 10.dp)
            .heightIn(min = 26.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        when (state) {
            SessionCardState.WORKING -> Box(Modifier.size(6.dp).clip(PillShape).background(tint))
            SessionCardState.NEEDS_YOU -> Icon(AgentIcons.hand, contentDescription = null, tint = tint, modifier = Modifier.size(11.dp))
            SessionCardState.FAILED -> Icon(AppIcons.warning, contentDescription = null, tint = tint, modifier = Modifier.size(11.dp))
            else -> Unit
        }
        Text(stateLabel(state), style = PeeringText.captionSemibold.copy(fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold), color = tint, maxLines = 1)
    }
}

@Composable
private fun stateLabel(state: SessionCardState): String = stringResource(
    when (state) {
        SessionCardState.WORKING -> R.string.agents_state_working
        SessionCardState.NEEDS_YOU -> R.string.agents_state_needs_you
        SessionCardState.IDLE -> R.string.agents_state_finished
        SessionCardState.ENDED -> R.string.agents_state_ended
        SessionCardState.FAILED -> R.string.agents_state_failed
        SessionCardState.PAUSED -> R.string.agents_state_paused
    },
)

private fun stateColor(state: SessionCardState): Color = when (state) {
    SessionCardState.NEEDS_YOU -> PeeringColors.caution
    SessionCardState.FAILED -> PeeringColors.danger
    SessionCardState.WORKING -> PeeringColors.ink.copy(alpha = 0.85f)
    SessionCardState.IDLE -> PeeringColors.ink.copy(alpha = 0.5f)
    SessionCardState.ENDED, SessionCardState.PAUSED -> PeeringColors.ink.copy(alpha = 0.4f)
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
