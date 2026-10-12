package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

private class Suggestion(val title: Int, val detail: Int)

private val suggestions = listOf(
    Suggestion(R.string.agents_suggestion_overview, R.string.agents_suggestion_overview_detail),
    Suggestion(R.string.agents_suggestion_tests, R.string.agents_suggestion_tests_detail),
    Suggestion(R.string.agents_suggestion_review, R.string.agents_suggestion_review_detail),
)

/** A chat before its first message: the mascot, a question, and three ways to begin. An ended chat only says so. */
@Composable
fun EmptyChat(ui: ChatUi, onSuggest: (String) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        EmptyState(
            icon = null,
            title = stringResource(R.string.agents_empty_chat_title),
            body = if (ui.ended) stringResource(R.string.agents_empty_chat_ended) else ui.directory,
            mascot = true,
        )
        if (!ui.ended) {
            suggestions.forEach { suggestion ->
                val title = stringResource(suggestion.title)
                SuggestionRow(title, stringResource(suggestion.detail)) { onSuggest(title) }
            }
        }
    }
}

@Composable
private fun SuggestionRow(title: String, detail: String, onClick: () -> Unit) {
    OutlinedPanel(
        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(MaterialTheme.shapes.large).clickable(onClick = onClick),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = PeeringColors.ink)
        Text(detail, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
    }
}
