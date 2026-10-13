package pl.dmq.peering.feature.agents.review

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.changes.DiffCounts
import pl.dmq.peering.session.agent.changes.ReviewFile
import pl.dmq.peering.session.agent.changes.ReviewGroup
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * Every changed file in every open chat, grouped by chat, each with a mark for "I have looked at this". A tap opens the
 * chat's Changes screen on that file, where comments can be written and sent back.
 */
@Composable
fun ReviewScreen(inbox: ReviewInbox, onOpenFile: (chatId: String, path: String) -> Unit, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val queue by inbox.queue.collectAsState()
    BackHandler(onBack = onClose)
    Surface(modifier.fillMaxSize(), color = PeeringColors.backdrop) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) {
                    Icon(AppIcons.close, contentDescription = stringResource(R.string.changes_close), tint = PeeringColors.ink)
                }
                Text(stringResource(R.string.review_title), style = PeeringText.headline, color = PeeringColors.ink, modifier = Modifier.weight(1f))
            }
            val groups = queue.visible
            if (groups.isEmpty()) {
                EmptyState(icon = AppIcons.checkCircle, title = stringResource(R.string.review_empty_title), body = stringResource(R.string.review_empty_body), modifier = Modifier.padding(top = 40.dp))
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 28.dp)) {
                    groups.forEach { group ->
                        item(key = "head-${group.chatId}") { GroupHeader(group, onToggleAll = { inbox.toggleAll(group) }) }
                        if (group.status == ReviewGroup.Status.CURRENT) {
                            items(group.files, key = { "${group.chatId}:${it.path}" }) { entry ->
                                FileRow(
                                    entry,
                                    onToggle = { inbox.setReviewed(group.chatId, entry.file, !entry.reviewed) },
                                    onOpen = { onOpenFile(group.chatId, entry.path) },
                                )
                                HorizontalDivider(color = PeeringColors.hairline)
                            }
                        } else {
                            item(key = "note-${group.chatId}") { Note(group.status) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GroupHeader(group: ReviewGroup, onToggleAll: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.weight(1f)) {
            Text(group.title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(group.directory, style = PeeringText.caption2Monospaced, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (group.files.isNotEmpty()) {
            Text(
                stringResource(if (group.pending.isEmpty()) R.string.review_unmark_all else R.string.review_mark_all),
                style = PeeringText.footnoteMedium,
                color = PeeringColors.accent,
                modifier = Modifier.tappable(onToggleAll).padding(vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun FileRow(entry: ReviewFile, onToggle: () -> Unit, onOpen: () -> Unit) {
    val label = stringResource(R.string.review_mark_reviewed)
    Row(Modifier.fillMaxWidth().tappable(onOpen).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(
            onClick = onToggle,
            modifier = Modifier.semantics {
                contentDescription = label
                role = Role.Checkbox
            },
        ) {
            Icon(
                if (entry.reviewed) AppIcons.checkCircleFilled else AppIcons.circle,
                contentDescription = null,
                tint = if (entry.reviewed) PeeringColors.accent else PeeringColors.tertiary,
                modifier = Modifier.size(22.dp),
            )
        }
        Column(Modifier.weight(1f).padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                entry.path.substringAfterLast('/'),
                style = PeeringText.subheadlineMedium,
                color = if (entry.reviewed) PeeringColors.muted else PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val folder = entry.path.substringBeforeLast('/', "")
            if (folder.isNotEmpty()) Text(folder, style = PeeringText.caption2Monospaced, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        DiffCounts(entry.file.added, entry.file.removed)
    }
}

@Composable
private fun Note(status: ReviewGroup.Status) {
    Text(
        stringResource(if (status == ReviewGroup.Status.NOT_REPOSITORY) R.string.review_not_repository else R.string.review_checking),
        style = PeeringText.footnote,
        color = PeeringColors.muted,
        modifier = Modifier.padding(vertical = 8.dp),
    )
}
