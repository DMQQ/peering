package pl.dmq.peering.feature.agents.changes

import pl.dmq.peering.ui.kit.tonalCard
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.changes.DiffLine
import pl.dmq.peering.session.agent.changes.DiffLineKind
import pl.dmq.peering.session.agent.changes.ReviewComment
import pl.dmq.peering.session.agent.changes.ReviewDiff
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.AgentChangeKind

private sealed interface CommentTarget {
    data object WholeFile : CommentTarget

    data class OnLine(val line: DiffLine) : CommentTarget
}

/** One changed file's diff, with a comment on a line or on the whole file. */
@Composable
fun ChangeFileScreen(changes: ChangesPresenter, entry: ChangeEntryUi, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val ui by changes.ui.collectAsState()
    val lines = remember(entry.diff) { entry.diff?.let(ReviewDiff::lines).orEmpty() }
    val fileComments = ui.comments.filter { it.path == entry.path }
    var target by remember { mutableStateOf<CommentTarget?>(null) }
    BackHandler { if (target != null) target = null else onBack() }

    Column(modifier.fillMaxSize()) {
        ChangeFileBar(entry.name, onBack, onComment = { target = CommentTarget.WholeFile })
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 28.dp)) {
            item(key = "header") { Header(entry) }
            if (lines.isEmpty()) {
                item(key = "none") {
                    Text(stringResource(R.string.changes_no_diff), style = PeeringText.subheadline, color = PeeringColors.muted, modifier = Modifier.padding(top = 12.dp))
                }
            } else {
                item(key = "diff") { DiffBlock(lines, ui.comments.filter { it.path == entry.path && it.line != null }, selected = (target as? CommentTarget.OnLine)?.line, onPick = { target = CommentTarget.OnLine(it) }, onRemove = changes::removeComment) }
            }
            items(fileComments.filter { it.line == null }, key = { "c${it.id}" }) { CommentCard(it, changes::removeComment, Modifier.padding(top = 12.dp)) }
        }
        target?.let { current ->
            CommentComposer(
                label = describe(entry.path, current),
                onAdd = { text ->
                    changes.addComment(entry.path, text, (current as? CommentTarget.OnLine)?.line)
                    target = null
                },
                onCancel = { target = null },
            )
        }
    }
}

@Composable
private fun ChangeFileBar(name: String, onBack: () -> Unit, onComment: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(AppIcons.back, contentDescription = stringResource(R.string.changes_back), tint = PeeringColors.ink)
        }
        Text(
            name,
            style = PeeringText.subheadlineSemibold.copy(fontSize = 17.sp),
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onComment) {
            Icon(AppIcons.edit, contentDescription = stringResource(R.string.changes_comment_file), tint = PeeringColors.ink)
        }
    }
}

private fun describe(path: String, target: CommentTarget): String = when (target) {
    CommentTarget.WholeFile -> path
    is CommentTarget.OnLine -> "$path:${target.line.commentNumber ?: 0}"
}

@Composable
private fun Header(entry: ChangeEntryUi) {
    Column(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(entry.path, style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.ink.copy(alpha = 0.8f))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(kindTitle(entry.kind), style = PeeringText.caption, color = PeeringColors.muted)
            DiffCounts(entry.added, entry.removed, size = 12)
        }
    }
}

@Composable
private fun kindTitle(kind: AgentChangeKind): String = stringResource(
    when (kind) {
        AgentChangeKind.MODIFIED -> R.string.changes_kind_modified
        AgentChangeKind.ADDED -> R.string.changes_kind_added
        AgentChangeKind.DELETED -> R.string.changes_kind_deleted
        AgentChangeKind.UNTRACKED -> R.string.changes_kind_untracked
    },
)

@Composable
private fun DiffBlock(
    lines: List<DiffLine>,
    comments: List<ReviewComment>,
    selected: DiffLine?,
    onPick: (DiffLine) -> Unit,
    onRemove: (Long) -> Unit,
) {
    val shape = peeringShapes.extraSmall
    Column(Modifier.fillMaxWidth().tonalCard(shape)) {
        lines.forEach { line ->
            DiffRow(line, selected = line == selected, onClick = { onPick(line) })
            comments.filter { it.line == line.commentNumber && it.onRemovedLine == (line.kind == DiffLineKind.REMOVED) && line.isCommentable }
                .forEach { CommentCard(it, onRemove, Modifier.padding(horizontal = 8.dp).padding(bottom = 6.dp)) }
        }
    }
}

@Composable
private fun DiffRow(line: DiffLine, selected: Boolean, onClick: () -> Unit) {
    val fill = diffFill(line.kind, selected)
    val mark = diffMark(line.kind)
    val markColour = diffMarkColour(line.kind)
    val textAlpha = diffTextAlpha(line.kind)
    val mono = PeeringText.caption.copy(fontFamily = FontFamily.Monospace)
    Row(
        Modifier
            .fillMaxWidth()
            .background(fill)
            .clickable(enabled = line.isCommentable, role = Role.Button, onClick = onClick)
            .padding(horizontal = 8.dp, vertical = if (line.kind == DiffLineKind.HUNK) 5.dp else 1.5.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            (line.newNumber ?: line.oldNumber)?.toString().orEmpty(),
            style = mono.copy(fontSize = 10.sp),
            color = PeeringColors.ink.copy(alpha = 0.35f),
            modifier = Modifier.width(30.dp),
            textAlign = TextAlign.End,
        )
        Text(mark, style = mono.copy(fontWeight = FontWeight.SemiBold), color = markColour, modifier = Modifier.width(9.dp))
        Text(line.text, style = mono, color = PeeringColors.ink.copy(alpha = textAlpha), modifier = Modifier.weight(1f))
    }
}

@Composable
private fun diffFill(kind: DiffLineKind, selected: Boolean): Color = when {
    selected -> PeeringColors.ink.copy(alpha = 0.14f)
    kind == DiffLineKind.ADDED -> PeeringColors.added.copy(alpha = 0.14f)
    kind == DiffLineKind.REMOVED -> PeeringColors.danger.copy(alpha = 0.14f)
    kind == DiffLineKind.HUNK -> PeeringColors.ink.copy(alpha = 0.04f)
    else -> Color.Transparent
}

private fun diffMark(kind: DiffLineKind): String = when (kind) {
    DiffLineKind.ADDED -> "+"
    DiffLineKind.REMOVED -> "-"
    DiffLineKind.HUNK -> "@"
    DiffLineKind.CONTEXT -> " "
}

@Composable
private fun diffMarkColour(kind: DiffLineKind): Color = when (kind) {
    DiffLineKind.ADDED -> PeeringColors.added
    DiffLineKind.REMOVED -> PeeringColors.danger
    else -> PeeringColors.ink.copy(alpha = 0.3f)
}

private fun diffTextAlpha(kind: DiffLineKind): Float = when (kind) {
    DiffLineKind.ADDED -> 0.95f
    DiffLineKind.REMOVED -> 0.8f
    DiffLineKind.CONTEXT -> 0.7f
    DiffLineKind.HUNK -> 0.4f
}
