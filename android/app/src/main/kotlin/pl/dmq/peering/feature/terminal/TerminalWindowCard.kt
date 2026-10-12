package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentIcons
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private const val PREVIEW_REFRESH_MILLIS = 500L

/** What a card shows of a shell's screen, read twice a second and not on every frame, so output never recomposes the list. */
@Composable
private fun rememberPreview(sessions: TerminalSessions, card: TerminalCard): State<List<String>> =
    produceState(emptyList(), card.id, card.isRunning) {
        if (!card.isRunning) {
            value = emptyList()
            return@produceState
        }
        val frames = sessions.frames(card.id)
        while (true) {
            value = TerminalListPresenter.previewLines(frames.value)
            delay(PREVIEW_REFRESH_MILLIS)
        }
    }

/** A shell as a small window onto the computer: name and state on a title bar, its last lines underneath. A long press offers Rename and End. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TerminalWindowCard(
    sessions: TerminalSessions,
    card: TerminalCard,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val preview by rememberPreview(sessions, card)
    val rename = stringResource(R.string.terminal_rename)
    val end = stringResource(R.string.terminal_end)
    Box(modifier) {
        TerminalWindowFrame(
            Modifier
                .combinedClickable(
                    onClick = onOpen,
                    onLongClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        menuOpen = true
                    },
                )
                .semantics {
                    customActions = listOf(
                        CustomAccessibilityAction(rename) { onRename(); true },
                        CustomAccessibilityAction(end) { onEnd(); true },
                    )
                },
        ) {
            TerminalWindowTitle(46.dp) {
                TerminalWindowDots()
                Spacer(Modifier.width(10.dp))
                CardName(card.name, Modifier.weight(1f))
                Spacer(Modifier.width(6.dp))
                CardStatus(card.state)
                Spacer(Modifier.width(10.dp))
                Icon(AppIcons.chevronRight, contentDescription = null, tint = Color.White.copy(alpha = 0.3f), modifier = Modifier.size(14.dp))
            }
            CardScreen(preview, card.isRunning)
        }
        PeeringMenu(menuOpen, { menuOpen = false }) {
            PeeringMenuItem(
                title = rename,
                icon = AppIcons.edit,
                onClick = {
                    menuOpen = false
                    onRename()
                },
            )
            PeeringMenuItem(
                title = end,
                icon = AppIcons.close,
                destructive = true,
                onClick = {
                    menuOpen = false
                    onEnd()
                },
            )
        }
    }
}

@Composable
private fun CardName(name: String, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(
            name,
            style = PeeringText.subheadlineSemibold.copy(fontSize = 13.5.sp, lineHeight = 18.sp),
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(AppIcons.computer, contentDescription = null, tint = Color.White.copy(alpha = 0.45f), modifier = Modifier.size(11.dp))
            Text(
                stringResource(R.string.terminal_card_host),
                fontSize = 10.5.sp,
                lineHeight = 14.sp,
                color = Color.White.copy(alpha = 0.45f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun CardStatus(state: TerminalCardState) {
    when (state) {
        TerminalCardState.RUNNING -> Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(6.dp).background(PeeringColors.added, CircleShape))
            Text(stringResource(R.string.terminal_card_running), fontSize = 11.5.sp, fontFamily = FontFamily.Monospace, color = Color.White.copy(alpha = 0.6f))
        }
        TerminalCardState.PASSWORD, TerminalCardState.CONFIRMATION -> Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(AgentIcons.hand, contentDescription = null, tint = PeeringColors.caution, modifier = Modifier.size(13.dp))
            Text(
                stringResource(if (state == TerminalCardState.PASSWORD) R.string.terminal_card_password else R.string.terminal_card_confirm),
                fontSize = 11.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = PeeringColors.caution,
            )
        }
        TerminalCardState.FAILED ->
            Text(stringResource(R.string.terminal_card_failed), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = PeeringColors.danger)
        TerminalCardState.EXITED -> Text(stringResource(R.string.terminal_card_exited), style = PeeringText.caption, color = PeeringColors.muted)
    }
}

@Composable
private fun CardScreen(lines: List<String>, running: Boolean) {
    TerminalWindowBody(horizontal = 14.dp, vertical = 11.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (lines.isEmpty() && !running) {
                Text(stringResource(R.string.terminal_card_idle), fontSize = 11.5.sp, fontFamily = FontFamily.Monospace, color = Color.White.copy(alpha = 0.35f))
            }
            lines.forEachIndexed { index, line ->
                val last = index == lines.lastIndex
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        line,
                        modifier = Modifier.weight(1f, fill = false),
                        fontSize = 11.5.sp,
                        fontFamily = FontFamily.Monospace,
                        color = Color.White.copy(alpha = if (last) 0.85f else 0.5f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (last && running) CardCaret()
                }
            }
            if (lines.isEmpty() && running) CardCaret()
        }
    }
}

@Composable
private fun CardCaret() {
    Box(Modifier.padding(start = 3.dp).size(width = 6.dp, height = 12.dp).background(Color.White.copy(alpha = 0.8f)))
}
