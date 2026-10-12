package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.ToolStatus
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** One tool call. Collapsed it shows the call and its status; open it shows the diff and the output. */
@Composable
fun ToolCallCard(row: TranscriptRow.ToolCall, expanded: Boolean, onToggle: () -> Unit) {
    OutlinedPanel(modifier = Modifier.fillMaxWidth().clip(MaterialTheme.shapes.large).clickable(onClick = onToggle)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text(
                row.call.title,
                style = MaterialTheme.typography.titleSmall,
                color = PeeringColors.ink,
                maxLines = 1,
                modifier = Modifier.padding(end = 8.dp),
            )
            Text(statusLabel(row.status), style = MaterialTheme.typography.labelMedium, color = statusColor(row.status))
        }
        row.call.detail?.takeIf { it.isNotBlank() }?.let { detail ->
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = PeeringColors.muted,
                maxLines = if (expanded) Int.MAX_VALUE else 2,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        if (expanded) {
            row.call.diff?.takeIf { it.isNotBlank() }?.let { DiffLines(it) }
            row.output?.let { output ->
                SelectionContainer {
                    Text(
                        output,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = PeeringColors.muted,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
            if (row.truncated) {
                Text(
                    stringResource(R.string.agents_output_truncated),
                    style = MaterialTheme.typography.labelSmall,
                    color = PeeringColors.faint,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun DiffLines(diff: String) {
    Column(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        diff.lines().forEach { line ->
            Text(
                line,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = when {
                    line.startsWith("+") -> PeeringColors.added
                    line.startsWith("-") -> PeeringColors.danger
                    else -> PeeringColors.muted
                },
            )
        }
    }
}

@Composable
private fun statusLabel(status: ToolStatus): String = when (status) {
    ToolStatus.Running -> stringResource(R.string.agents_tool_running)
    is ToolStatus.AwaitingApproval -> stringResource(R.string.agents_state_needs_you)
    ToolStatus.Denied -> stringResource(R.string.agents_tool_denied)
    ToolStatus.Ok -> stringResource(R.string.agents_tool_done)
    ToolStatus.Failed -> stringResource(R.string.agents_tool_failed)
}

private fun statusColor(status: ToolStatus) = when (status) {
    is ToolStatus.AwaitingApproval -> PeeringColors.caution
    ToolStatus.Failed, ToolStatus.Denied -> PeeringColors.danger
    ToolStatus.Ok -> PeeringColors.added
    ToolStatus.Running -> PeeringColors.muted
}
