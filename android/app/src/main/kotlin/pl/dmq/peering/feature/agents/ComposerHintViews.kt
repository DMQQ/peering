package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.files.FileGlyph
import pl.dmq.peering.feature.files.icon
import pl.dmq.peering.session.agent.MentionQuery
import pl.dmq.peering.session.agent.SlashDetail
import pl.dmq.peering.session.agent.SlashKind
import pl.dmq.peering.session.agent.SlashSuggestion
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.RemoteDirectoryEntry

private val PanelShape get() = peeringShapes.medium
private const val MENTION_LIMIT = 6

@Composable
internal fun ComposerHintPanel(hint: ComposerHint, onSlash: (SlashSuggestion) -> Unit, onMention: (MentionQuery, String, Boolean) -> Unit) {
    when (hint) {
        ComposerHint.None -> Unit
        is ComposerHint.Slash -> SlashList(hint.items, onSlash)
        is ComposerHint.Mention -> MentionList(hint, onMention)
    }
}

@Composable
private fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier.padding(horizontal = 16.dp).fillMaxWidth()
            .clip(PanelShape)
            .background(PeeringColors.containerHigh)
            .border(1.dp, PeeringColors.hairline, PanelShape),
    ) { content() }
}

@Composable
private fun SlashList(items: List<SlashSuggestion>, onPick: (SlashSuggestion) -> Unit) {
    Panel(Modifier.heightIn(max = 264.dp)) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            if (items.isEmpty()) Note(stringResource(R.string.hints_nothing_matches))
            items.forEachIndexed { index, item ->
                if (index > 0) HorizontalDivider(Modifier.padding(start = 46.dp), color = PeeringColors.hairline)
                SlashRow(item, onPick)
            }
        }
    }
}

@Composable
private fun SlashRow(item: SlashSuggestion, onPick: (SlashSuggestion) -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).tappable({ onPick(item) }).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Icon(item.kind.icon, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.8f), modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f)) {
            Text("/" + item.name, style = PeeringText.subheadlineMedium.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.ink, maxLines = 1)
            Text(stringResource(item.detail.text), style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(stringResource(item.kind.tag), style = PeeringText.caption2.copy(fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold), color = PeeringColors.muted)
    }
}

@Composable
private fun MentionList(hint: ComposerHint.Mention, onPick: (MentionQuery, String, Boolean) -> Unit) {
    val shown = hint.matches.take(MENTION_LIMIT)
    Panel {
        Row(Modifier.fillMaxWidth().heightIn(min = 34.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Outlined.AlternateEmail, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(14.dp))
            Text(
                hint.query.folderPart.ifEmpty { stringResource(R.string.hints_in_project) },
                style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace, fontSize = 11.5.sp),
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        HorizontalDivider(color = PeeringColors.hairline)
        when {
            hint.failure != null -> Note(hint.failure)
            shown.isEmpty() -> Note(if (hint.loading) stringResource(R.string.hints_looking) else stringResource(R.string.hints_nothing_starts, hint.query.namePart))
            else -> {
                shown.forEachIndexed { index, entry ->
                    if (index > 0) HorizontalDivider(Modifier.padding(start = 46.dp), color = PeeringColors.hairline)
                    MentionRow(entry) { onPick(hint.query, hint.query.folderPart + entry.name, entry.isDirectory) }
                }
                val more = hint.matches.size - shown.size
                if (more > 0) {
                    Text(
                        pluralStringResource(R.plurals.hints_more, more, more),
                        style = PeeringText.caption2,
                        color = PeeringColors.tertiary,
                        modifier = Modifier.padding(horizontal = 14.dp).padding(bottom = 8.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun MentionRow(entry: RemoteDirectoryEntry, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 40.dp).tappable(onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Icon(FileGlyph.of(entry).icon, contentDescription = null, tint = PeeringColors.ink.copy(alpha = 0.85f), modifier = Modifier.size(20.dp))
        Text(entry.name, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Icon(if (entry.isDirectory) AppIcons.chevronRight else SessionIcons.add, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = PeeringText.footnote, color = PeeringColors.muted, modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp))
}

private val SlashKind.icon: ImageVector get() = when (this) {
    SlashKind.APP -> SessionIcons.phone
    SlashKind.BUILTIN -> AppIcons.command
    SlashKind.COMMAND -> AppIcons.code
    SlashKind.SKILL -> AppIcons.sparkles
}

private val SlashKind.tag: Int get() = when (this) {
    SlashKind.APP -> R.string.hints_tag_app
    SlashKind.BUILTIN -> R.string.hints_tag_builtin
    SlashKind.COMMAND -> R.string.hints_tag_command
    SlashKind.SKILL -> R.string.hints_tag_skill
}

private val SlashDetail.text: Int get() = when (this) {
    SlashDetail.USAGE -> R.string.hints_usage
    SlashDetail.MODEL -> R.string.hints_model
    SlashDetail.RENAME -> R.string.hints_rename
    SlashDetail.COMPACT -> R.string.hints_compact
    SlashDetail.CLEAR -> R.string.hints_clear
    SlashDetail.THIS_PROJECT -> R.string.hints_this_project
    SlashDetail.YOURS -> R.string.hints_yours
}
