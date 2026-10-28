package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.ToolStatus
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * One tool call as the iPhone draws it: a status tile, the title with the call in monospace, and a status mark at the
 * end. A tap opens the diff and output, or the approval sheet when the call is waiting on a yes. A long press copies.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ToolCallCard(row: TranscriptRow.ToolCall, expanded: Boolean, onToggle: () -> Unit, onReview: ((String) -> Unit)?) {
    var menuOpen by remember { mutableStateOf(false) }
    val awaiting = row.status as? ToolStatus.AwaitingApproval
    Box {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(peeringShapes.small)
                .background(PeeringColors.containerHigh, peeringShapes.small)
                .combinedClickable(onClick = { if (awaiting != null && onReview != null) onReview(awaiting.approvalID) else onToggle() }, onLongClick = { menuOpen = true })
                .padding(11.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Header(row, expanded)
            if (expanded) Details(row)
        }
        ToolCallMenu(row, expanded, menuOpen, onDismiss = { menuOpen = false }, onToggle = onToggle)
    }
}

@Composable
private fun ToolCallMenu(row: TranscriptRow.ToolCall, expanded: Boolean, open: Boolean, onDismiss: () -> Unit, onToggle: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    PeeringMenu(open, onDismiss) {
        row.output?.takeIf { it.isNotEmpty() }?.let { output ->
            PeeringMenuItem(stringResource(R.string.agents_copy_output), icon = AppIcons.copy, onClick = {
                onDismiss()
                clipboard.setText(AnnotatedString(output))
            })
        }
        row.call.detail?.takeIf { it.isNotEmpty() }?.let { detail ->
            PeeringMenuItem(stringResource(R.string.agents_copy_call, row.call.title), icon = AppIcons.copy, onClick = {
                onDismiss()
                clipboard.setText(AnnotatedString(detail))
            })
        }
        PeeringMenuItem(
            stringResource(if (expanded) R.string.agents_hide_details else R.string.agents_show_details),
            icon = AppIcons.expand,
            onClick = {
                onDismiss()
                onToggle()
            },
        )
    }
}

@Composable
private fun Header(row: TranscriptRow.ToolCall, expanded: Boolean) {
    val tint = tint(row.status)
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        Box(
            Modifier.size(28.dp).clip(peeringShapes.extraSmall).background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(statusIcon(row.status), contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(row.call.title, style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
            row.call.detail?.takeIf { it.isNotBlank() }?.let { detail ->
                Text(
                    detail,
                    style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace),
                    color = PeeringColors.ink.copy(alpha = 0.55f),
                    maxLines = if (expanded) Int.MAX_VALUE else 2,
                )
            }
        }
        Box(Modifier.height(28.dp), contentAlignment = Alignment.Center) { StatusMark(row.status) }
    }
}

@Composable
private fun Details(row: TranscriptRow.ToolCall) {
    row.call.diff?.takeIf { it.isNotBlank() }?.let { DiffBlock(it) }
    row.output?.takeIf { it.isNotEmpty() }?.let { output ->
        SelectionContainer {
            Text(
                if (row.truncated) output + "\n" + stringResource(R.string.agents_output_truncated_marker) else output,
                style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace, fontSize = 11.5.sp),
                color = PeeringColors.ink.copy(alpha = 0.7f),
                modifier = Modifier.fillMaxWidth().clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.06f)).padding(10.dp),
            )
        }
    }
    if (row.call.diff == null && row.output == null && row.status == ToolStatus.Running) {
        Text(stringResource(R.string.agents_tool_running_ellipsis), style = PeeringText.caption, color = PeeringColors.ink.copy(alpha = 0.5f))
    }
}

@Composable
private fun DiffBlock(diff: String) {
    Column(Modifier.fillMaxWidth().clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.06f)).padding(10.dp)) {
        diff.lines().forEach { line ->
            Text(
                line,
                style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace, fontSize = 11.5.sp),
                color = when {
                    line.startsWith("+") -> PeeringColors.added
                    line.startsWith("-") -> PeeringColors.danger
                    else -> PeeringColors.ink.copy(alpha = 0.6f)
                },
            )
        }
    }
}

@Composable
private fun StatusMark(status: ToolStatus) {
    when (status) {
        ToolStatus.Running -> CircularProgressIndicator(
            modifier = Modifier.size(14.dp),
            strokeWidth = 1.5.dp,
            color = PeeringColors.ink.copy(alpha = 0.6f),
        )
        is ToolStatus.AwaitingApproval -> Text(
            stringResource(R.string.agents_tool_review),
            style = PeeringText.captionSemibold,
            color = PeeringColors.onInk,
            modifier = Modifier.clip(PillShape).background(PeeringColors.ink).padding(horizontal = 11.dp, vertical = 4.dp),
        )
        ToolStatus.Denied -> Text(stringResource(R.string.agents_tool_denied), style = PeeringText.caption2, color = PeeringColors.caution)
        ToolStatus.Failed -> Text(stringResource(R.string.agents_tool_failed), style = PeeringText.caption2, color = PeeringColors.danger)
        ToolStatus.Ok -> Icon(AppIcons.check, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.45f), modifier = Modifier.size(14.dp))
    }
}

private fun statusIcon(status: ToolStatus): ImageVector = when (status) {
    is ToolStatus.AwaitingApproval -> AgentIcons.hand
    ToolStatus.Denied -> AgentIcons.denied
    ToolStatus.Failed -> AppIcons.close
    ToolStatus.Ok -> AppIcons.check
    ToolStatus.Running -> AgentIcons.more
}

private fun tint(status: ToolStatus): Color = when (status) {
    is ToolStatus.AwaitingApproval, ToolStatus.Denied -> PeeringColors.caution
    ToolStatus.Failed -> PeeringColors.danger
    ToolStatus.Ok, ToolStatus.Running -> PeeringColors.ink.copy(alpha = 0.85f)
}
