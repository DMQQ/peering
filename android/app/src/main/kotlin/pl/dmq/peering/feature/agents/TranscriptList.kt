package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.ApprovalStatus
import pl.dmq.peering.session.agent.PendingApproval
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.theme.PeeringColors

/** The selected chat's conversation. It follows new rows to the bottom until the user scrolls away from it. */
@Composable
fun TranscriptList(presenter: TranscriptPresenter, port: AgentsPort, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    val listState = rememberLazyListState()
    val lastIndex = ui.rows.size + ui.queuedPrompts.size - 1

    LaunchedEffect(lastIndex, ui.following) {
        if (ui.following && lastIndex >= 0) listState.animateScrollToItem(lastIndex)
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling -> if (!scrolling) presenter.onUserScrolled(atBottom = listState.isAtEnd()) }
    }

    Column(modifier = modifier.fillMaxSize()) {
        if (ui.loadingHistory && ui.rows.isEmpty()) {
            Text(
                stringResource(R.string.agents_history_loading),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                modifier = Modifier.padding(16.dp),
            )
        }
        if (ui.truncatedAtFront) {
            Text(
                stringResource(R.string.agents_history_truncated),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.faint,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        Box(modifier = Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(ui.rows, key = { it.id }) { row ->
                    TranscriptRowView(
                        row = row,
                        sessionID = ui.sessionID,
                        port = port,
                        expanded = row.id in ui.expandedToolIDs,
                        onToggleTool = { presenter.toggleTool(row.id) },
                    )
                }
                itemsIndexed(ui.queuedPrompts) { _, text -> QueuedPromptRow(text) }
            }
        }
        if (!ui.following && ui.unseenRows > 0) {
            TextButton(
                onClick = presenter::followLatest,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            ) {
                Text(
                    stringResource(R.string.agents_jump_to_latest, ui.unseenRows),
                    style = MaterialTheme.typography.labelLarge,
                    color = PeeringColors.ink,
                )
            }
        }
    }
}

@Composable
private fun TranscriptRowView(
    row: TranscriptRow,
    sessionID: String?,
    port: AgentsPort,
    expanded: Boolean,
    onToggleTool: () -> Unit,
) {
    when (row) {
        is TranscriptRow.User -> UserBubble(row.text)
        is TranscriptRow.AssistantText -> MarkdownText(row.text)
        is TranscriptRow.ToolCall -> ToolCallCard(row, expanded = expanded, onToggle = onToggleTool)
        is TranscriptRow.Plan -> PlanCard(row.steps)
        is TranscriptRow.Subagent -> SubagentStrip(row)
        is TranscriptRow.TurnSummary -> TurnSummaryPill(TurnSummaryUi.of(row.summary))
        is TranscriptRow.Notice -> Text(row.text, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
        is TranscriptRow.Failure -> Text(row.message, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.danger)
        is TranscriptRow.Approval -> ApprovalRowView(row, sessionID, port)
    }
}

private fun LazyListState.isAtEnd(): Boolean {
    val info = layoutInfo
    val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: return true
    return lastVisible >= info.totalItemsCount - 1
}

@Composable
private fun ApprovalRowView(row: TranscriptRow.Approval, sessionID: String?, port: AgentsPort) {
    val pending = row.status == ApprovalStatus.Pending
    if (pending && sessionID != null) {
        ApprovalCard(port, sessionID, PendingApproval(row.approvalID, row.call, row.reason))
    } else {
        Text(
            stringResource(if (row.status is ApprovalStatus.Answered) R.string.approval_answered else R.string.approval_cancelled),
            style = MaterialTheme.typography.bodySmall,
            color = PeeringColors.muted,
        )
    }
}
