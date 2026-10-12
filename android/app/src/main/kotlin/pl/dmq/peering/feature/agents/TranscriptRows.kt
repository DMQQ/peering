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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.ui.theme.PillShape

private val bubbleShape get() = peeringShapes.extraSmall

/** What you said: right aligned in a tinted bubble. A long press copies it or asks it again. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun UserBubble(text: String, canAskAgain: Boolean, onAskAgain: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var menuOpen by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Box(Modifier.padding(start = 40.dp)) {
            Text(
                text = text,
                style = PeeringText.body.copy(fontSize = 16.sp),
                color = PeeringColors.ink,
                modifier = Modifier
                    .clip(bubbleShape)
                    .background(PeeringColors.ink.copy(alpha = 0.07f))
                    .border(1.dp, PeeringColors.ink.copy(alpha = 0.07f), bubbleShape)
                    .combinedClickable(onClick = { menuOpen = true }, onLongClick = { menuOpen = true })
                    .padding(horizontal = 12.dp, vertical = 9.dp),
            )
            PeeringMenu(menuOpen, { menuOpen = false }) {
                PeeringMenuItem(stringResource(R.string.agents_copy), icon = AppIcons.copy, onClick = {
                    menuOpen = false
                    clipboard.setText(AnnotatedString(text))
                })
                if (canAskAgain) {
                    PeeringMenuItem(stringResource(R.string.agents_ask_again), icon = AgentIcons.replay, onClick = {
                        menuOpen = false
                        onAskAgain()
                    })
                }
            }
        }
    }
}

/** A message waiting behind the running turn: dashed, dimmed, with a clock pill saying when it starts. */
@Composable
fun QueuedPromptRow(text: String, position: Int, total: Int) {
    val label = if (total > 1) stringResource(R.string.agents_queued_position, position, total) else stringResource(R.string.agents_queued_next)
    val dash = PathEffect.dashPathEffect(floatArrayOf(12f, 9f))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Column(Modifier.padding(start = 40.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text,
                style = PeeringText.body.copy(fontSize = 16.sp),
                color = PeeringColors.ink.copy(alpha = 0.6f),
                modifier = Modifier
                    .drawBehind {
                        drawRoundRect(
                            color = Color.White.copy(alpha = 0.2f),
                            cornerRadius = CornerRadius(12.dp.toPx()),
                            style = Stroke(width = 1.dp.toPx(), pathEffect = dash),
                        )
                    }
                    .padding(horizontal = 12.dp, vertical = 9.dp),
            )
            Row(
                modifier = Modifier
                    .clip(PillShape)
                    .background(PeeringColors.ink.copy(alpha = 0.08f))
                    .border(1.dp, PeeringColors.ink.copy(alpha = 0.14f), PillShape)
                    .padding(horizontal = 9.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(AgentIcons.clock, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.7f), modifier = Modifier.size(11.dp))
                Text(label, style = PeeringText.caption2.copy(fontSize = 11.sp), color = PeeringColors.ink.copy(alpha = 0.7f))
            }
        }
    }
}

@Composable
fun NoticeLine(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(AgentIcons.info, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.5f), modifier = Modifier.size(13.dp))
        Text(text, style = PeeringText.footnote, color = PeeringColors.ink.copy(alpha = 0.5f))
    }
}

@Composable
fun FailureLine(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(AppIcons.warning, contentDescription = null, tint = PeeringColors.danger, modifier = Modifier.size(13.dp))
        Text(text, style = PeeringText.footnote, color = PeeringColors.danger)
    }
}

/** What the turn cost, in monospace and quiet: Stopped or Failed first, then cost, tokens and time. */
@Composable
fun TurnSummaryPill(summary: TurnSummaryUi) {
    val parts = buildList {
        when (summary.status) {
            TurnStatus.STOPPED -> add(stringResource(R.string.agents_turn_stopped))
            TurnStatus.FAILED -> add(stringResource(R.string.agents_turn_failed))
            TurnStatus.DONE -> Unit
        }
        summary.costUSD?.let { add(stringResource(R.string.agents_turn_cost, String.format(Locale.US, "%.2f", it))) }
        val input = summary.inputTokens
        val output = summary.outputTokens
        if (input != null && output != null) add(stringResource(R.string.agents_turn_tokens, input, output))
        summary.durationSeconds?.let { add(stringResource(R.string.agents_turn_duration, it)) }
    }
    if (parts.isEmpty()) return
    Text(
        parts.joinToString("  "),
        style = PeeringText.caption2Monospaced,
        color = if (summary.status == TurnStatus.FAILED) PeeringColors.danger else PeeringColors.ink.copy(alpha = 0.45f),
        modifier = Modifier.padding(top = 2.dp),
    )
}

/** A small Material progress ring, then the word, while the agent works. The ring exists only while this row does. */
@Composable
fun ThinkingRow() {
    val label = stringResource(R.string.agents_state_working)
    Row(
        modifier = Modifier.padding(vertical = 4.dp).semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PeeringSpinner(size = 14.dp, color = PeeringColors.ink.copy(alpha = 0.6f))
        Text(label, style = PeeringText.footnote, color = PeeringColors.ink.copy(alpha = 0.5f))
    }
}

