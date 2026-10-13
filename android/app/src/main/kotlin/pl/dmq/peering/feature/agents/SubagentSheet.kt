package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.wire.AgentSessionState

/** One sub-agent a chat spawned: the `Task` call that started it, and what it has done since. */
data class SubagentView(val callID: String, val title: String?, val working: Boolean, val rows: List<TranscriptRow>) {
    companion object {
        /** Each sub-agent in the order it started. The title is the task's own description, absent when the call had none. */
        fun of(rows: List<TranscriptRow>): List<SubagentView> {
            val calls = rows.filterIsInstance<TranscriptRow.ToolCall>().associateBy { it.call.id }
            return rows.filterIsInstance<TranscriptRow.Subagent>().map { row ->
                SubagentView(
                    callID = row.parentCallID,
                    title = calls[row.parentCallID]?.call?.detail,
                    working = row.transcript.sessionState == AgentSessionState.WORKING,
                    rows = row.transcript.rows.filter { it !is TranscriptRow.Approval },
                )
            }
        }
    }
}

/** What the sub-agents a chat spawned did, one at a time, with a strip to move between them. */
@Composable
internal fun SubagentSheet(subagents: List<SubagentView>, selectedCallID: String, onSelect: (String) -> Unit, onDismiss: () -> Unit) {
    val selected = subagents.firstOrNull { it.callID == selectedCallID } ?: subagents.firstOrNull()
    var expanded by remember { mutableStateOf(emptySet<Long>()) }
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.agents_subagent_label)) {
        if (subagents.size > 1) SubagentChips(subagents, selected?.callID, onSelect)
        val state = rememberLazyListState()
        val count = selected?.rows?.size ?: 0
        LaunchedEffect(selected?.callID, count) {
            if (count > 0) state.animateScrollToItem(count - 1)
        }
        LazyColumn(
            state = state,
            modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
            contentPadding = PaddingValues(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(selected?.rows.orEmpty(), key = { it.id }) { row ->
                TranscriptRowView(
                    row = row,
                    expanded = row.id in expanded,
                    onToggleTool = { expanded = if (row.id in expanded) expanded - row.id else expanded + row.id },
                    onAskAgain = null,
                    onReview = null,
                )
            }
            if (selected?.working == true) item(key = "thinking") { ThinkingRow() }
        }
    }
}

@Composable
private fun SubagentChips(subagents: List<SubagentView>, selectedID: String?, onSelect: (String) -> Unit) {
    val fallback = stringResource(R.string.agents_subagent_label)
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        subagents.forEach { subagent ->
            val isSelected = subagent.callID == selectedID
            Row(
                Modifier
                    .heightIn(min = 32.dp)
                    .clip(PillShape)
                    .background(if (isSelected) PeeringColors.ink else androidx.compose.ui.graphics.Color.Transparent)
                    .border(1.dp, if (isSelected) androidx.compose.ui.graphics.Color.Transparent else PeeringColors.outline, PillShape)
                    .tappable({ onSelect(subagent.callID) })
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (subagent.working) {
                    CircularProgressIndicator(Modifier.size(12.dp), color = PeeringColors.muted, strokeWidth = 1.5.dp)
                }
                Text(
                    subagent.title ?: fallback,
                    style = PeeringText.footnote,
                    color = if (isSelected) PeeringColors.onInk else PeeringColors.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
