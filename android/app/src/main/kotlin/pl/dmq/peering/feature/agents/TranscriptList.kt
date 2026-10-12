package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * The selected chat's conversation, 10 apart. It follows new rows to the bottom until the user scrolls away from it.
 * Approvals are not rows here: the tool card they belong to says "Review" and the sheet carries the question.
 */
@Composable
fun TranscriptList(
    presenter: TranscriptPresenter,
    onAskAgain: (String) -> Unit,
    onReview: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    val listState = rememberLazyListState()
    val rows = remember(ui.rows) { ui.rows.filter { it !is TranscriptRow.Approval } }
    val lastIndex = (if (ui.truncatedAtFront) 1 else 0) + rows.size + ui.queuedPrompts.size + (if (ui.working) 1 else 0) - 1

    LaunchedEffect(lastIndex, ui.following) {
        if (ui.following && lastIndex >= 0) listState.animateScrollToItem(lastIndex)
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling -> if (!scrolling) presenter.onUserScrolled(atBottom = listState.isAtEnd()) }
    }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (ui.truncatedAtFront) {
            item(key = "truncated") {
                Text(
                    stringResource(R.string.agents_history_truncated),
                    style = PeeringText.caption,
                    color = PeeringColors.ink.copy(alpha = 0.45f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        itemsIndexed(rows, key = { _, row -> row.id }) { _, row ->
            TranscriptRowView(
                row = row,
                expanded = row.id in ui.expandedToolIDs,
                canAskAgain = !ui.working,
                onToggleTool = { presenter.toggleTool(row.id) },
                onAskAgain = onAskAgain,
                onReview = onReview,
            )
        }
        itemsIndexed(ui.queuedPrompts, key = { index, _ -> "queued-$index" }) { index, text ->
            QueuedPromptRow(text, position = index + 1, total = ui.queuedPrompts.size)
        }
        if (ui.working) item(key = "thinking") { ThinkingRow() }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TranscriptRowView(
    row: TranscriptRow,
    expanded: Boolean,
    canAskAgain: Boolean,
    onToggleTool: () -> Unit,
    onAskAgain: (String) -> Unit,
    onReview: (String) -> Unit,
) {
    when (row) {
        is TranscriptRow.User -> UserBubble(row.text, canAskAgain) { onAskAgain(row.text) }
        is TranscriptRow.AssistantText -> Reply(row.text)
        is TranscriptRow.ToolCall -> ToolCallCard(row, expanded = expanded, onToggle = onToggleTool, onReview = onReview)
        is TranscriptRow.Plan -> PlanCard(row.steps)
        is TranscriptRow.Subagent -> SubagentStrip(row)
        is TranscriptRow.TurnSummary -> TurnSummaryPill(TurnSummaryUi.of(row.summary))
        is TranscriptRow.Notice -> NoticeLine(row.text)
        is TranscriptRow.Failure -> FailureLine(row.message)
        is TranscriptRow.Approval -> Unit
    }
}

/** The agent's words as markdown; a long press copies them. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Reply(text: String) {
    val clipboard = LocalClipboardManager.current
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        MarkdownText(text, Modifier.combinedClickable(onClick = { menuOpen = true }, onLongClick = { menuOpen = true }))
        PeeringMenu(menuOpen, { menuOpen = false }) {
            PeeringMenuItem(stringResource(R.string.agents_copy), icon = AppIcons.copy, onClick = {
                menuOpen = false
                clipboard.setText(AnnotatedString(text))
            })
        }
    }
}

private fun LazyListState.isAtEnd(): Boolean {
    val info = layoutInfo
    val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: return true
    return lastVisible >= info.totalItemsCount - 1
}
