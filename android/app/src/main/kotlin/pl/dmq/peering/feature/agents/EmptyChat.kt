package pl.dmq.peering.feature.agents

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState

import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.session.agent.PromptTemplate
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

private class Suggestion(val icon: ImageVector, val title: Int, val detail: Int)

private val suggestions = listOf(
    Suggestion(AppIcons.document, R.string.agents_suggestion_overview, R.string.agents_suggestion_overview_detail),
    Suggestion(AppIcons.checkCircle, R.string.agents_suggestion_tests, R.string.agents_suggestion_tests_detail),
    Suggestion(AppIcons.code, R.string.agents_suggestion_review, R.string.agents_suggestion_review_detail),
)

/**
 * A new chat before its first message: who is on the other end, "What are we working on?", the guide until it is read,
 * and three ways to begin. An ended chat only says so.
 */
@Composable
fun EmptyChat(
    ui: ChatUi,
    templates: List<PromptTemplate>,
    onSuggest: (String) -> Unit,
    onSaveTemplate: (String) -> Unit,
    onRemoveTemplate: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var guideSeen by rememberSaveable { mutableStateOf(false) }
    var addingTemplate by remember { mutableStateOf(false) }
    Column(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        AgentTile(ui.agentID)
        ChatTitle(ui.ended)
        if (ui.ended) {
            EndedNote()
        } else {
            ChatStarters(
                guideSeen = guideSeen,
                onGuideSeen = { guideSeen = true },
                templates = templates,
                onSuggest = onSuggest,
                onRemoveTemplate = onRemoveTemplate,
                onAddTemplate = { addingTemplate = true },
            )
        }
    }
    if (addingTemplate) {
        SaveTemplateDialog(
            onSave = {
                onSaveTemplate(it)
                addingTemplate = false
            },
            onDismiss = { addingTemplate = false },
        )
    }
}

@Composable
private fun ChatTitle(ended: Boolean) {
    Text(
        stringResource(if (ended) R.string.agents_chat_ended_title else R.string.agents_empty_chat_title),
        style = PeeringText.display(size = 30f, tracking = -0.9f),
        color = PeeringColors.ink,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 8.dp),
    )
}

@Composable
private fun EndedNote() {
    Text(
        stringResource(R.string.agents_empty_chat_ended),
        style = PeeringText.footnote,
        color = PeeringColors.muted,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 14.dp, start = 12.dp, end = 12.dp),
    )
}

@Composable
private fun ChatStarters(
    guideSeen: Boolean,
    onGuideSeen: () -> Unit,
    templates: List<PromptTemplate>,
    onSuggest: (String) -> Unit,
    onRemoveTemplate: (String) -> Unit,
    onAddTemplate: () -> Unit,
) {
    Column(Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!guideSeen) ChatGuide(onGuideSeen)
        suggestions.forEach { suggestion ->
            val title = stringResource(suggestion.title)
            SuggestionRow(suggestion.icon, title, stringResource(suggestion.detail), onClick = { onSuggest(title) })
        }
        templates.forEach { template ->
            SuggestionRow(
                AgentIcons.savedPrompt,
                template.text,
                stringResource(R.string.agents_template_yours),
                onClick = { onSuggest(template.text) },
                removeLabel = stringResource(R.string.agents_template_remove),
                onRemove = { onRemoveTemplate(template.id) },
            )
        }
        AddTemplateButton(onAddTemplate)
    }
}

@Composable
private fun AddTemplateButton(onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        Icon(AgentIcons.plus, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.7f), modifier = Modifier.size(16.dp))
        Text(stringResource(R.string.agents_template_add), style = PeeringText.subheadlineMedium, color = PeeringColors.ink.copy(alpha = 0.7f))
    }
}

@Composable
private fun AgentTile(agentID: String) {
    val shape = peeringShapes.large
    Box(
        modifier = Modifier
            .size(88.dp)
            .clip(shape)
            .background(PeeringColors.ink.copy(alpha = 0.14f))
            .border(1.dp, PeeringColors.ink.copy(alpha = 0.3f), shape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(AgentBrand.of(agentID).icon(), contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(38.dp))
    }
}

@Composable
private fun ChatGuide(onDismiss: () -> Unit) {
    Column(Modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.agents_chat_guide_title), style = PeeringText.display(size = 22f, tracking = -0.5f), color = PeeringColors.ink)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            IconTile(AgentIcons.hand, size = 34.dp)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.agents_chat_guide_asks), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                Text(stringResource(R.string.agents_chat_guide_asks_detail), style = PeeringText.footnote, color = PeeringColors.muted)
            }
        }
        InkButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.agents_guide_got_it)) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SuggestionRow(
    icon: ImageVector,
    title: String,
    detail: String,
    onClick: () -> Unit,
    removeLabel: String? = null,
    onRemove: (() -> Unit)? = null,
) {
    val shape = peeringShapes.small
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 62.dp)
                .clip(shape)
                .background(PeeringColors.containerHigh)
                .combinedClickable(role = Role.Button, onClick = onClick, onLongClick = if (onRemove != null) ({ menuOpen = true }) else null)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconTile(icon, size = 34.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = PeeringText.subheadlineSemibold.copy(fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold), color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(detail, style = PeeringText.caption, color = PeeringColors.ink.copy(alpha = 0.5f), maxLines = 1)
            }
            Icon(AgentIcons.upLeft, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.35f), modifier = Modifier.size(12.dp))
        }
        if (onRemove != null && removeLabel != null) {
            PeeringMenu(menuOpen, { menuOpen = false }) {
                PeeringMenuItem(
                    title = removeLabel,
                    icon = AppIcons.delete,
                    destructive = true,
                    onClick = {
                        menuOpen = false
                        onRemove()
                    },
                )
            }
        }
    }
}
