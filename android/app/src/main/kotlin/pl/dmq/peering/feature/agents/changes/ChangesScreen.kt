package pl.dmq.peering.feature.agents.changes

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentIcons
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.changes.ReviewPromptWords
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.AgentChangeKind

/**
 * The files git reports as changed in a chat's folder, one tap from a diff each, with the way to commit and push them
 * and to send the comments written on them back to the agent. Back from a diff returns to the list, and back from the
 * list closes the screen.
 */
@Composable
fun ChangesScreen(
    changes: ChangesPresenter,
    commit: CommitPresenter,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by changes.ui.collectAsState()
    var openPath by remember { mutableStateOf<String?>(null) }
    var committing by remember { mutableStateOf(false) }
    val words = reviewPromptWords()
    LaunchedEffect(changes) { changes.refresh() }
    BackHandler(enabled = openPath == null, onBack = onClose)

    Surface(modifier.fillMaxSize(), color = PeeringColors.backdrop) {
        val path = openPath
        val entry = path?.let(changes::entry)
        if (path != null && entry != null) {
            ChangeFileScreen(changes, entry, onBack = { openPath = null })
        } else {
            Column(Modifier.fillMaxSize()) {
                TopBar(canCommit = ui.canCommit, onClose = onClose, onCommit = { committing = true })
                ChangeList(ui, onOpen = { openPath = it }, modifier = Modifier.weight(1f))
                BottomBar(
                    commentCount = ui.comments.size,
                    onRefresh = changes::refresh,
                    onSend = {
                        if (changes.sendReview(words)) onClose()
                    },
                )
            }
        }
    }
    if (committing) CommitSheet(commit, onDismiss = { committing = false })
}

@Composable
private fun reviewPromptWords(): ReviewPromptWords {
    val resources = LocalContext.current.resources
    return remember(resources) {
        ReviewPromptWords(
            intro = resources.getString(R.string.review_prompt_intro),
            removedLine = resources.getString(R.string.review_prompt_removed),
            moreLeftOut = { resources.getQuantityString(R.plurals.review_prompt_left_out, it, it) },
        )
    }
}

@Composable
private fun TopBar(canCommit: Boolean, onClose: () -> Unit, onCommit: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) {
            Icon(AppIcons.close, contentDescription = stringResource(R.string.changes_close), tint = PeeringColors.ink)
        }
        Text(
            stringResource(R.string.changes_title),
            style = PeeringText.subheadlineSemibold.copy(fontSize = 17.sp),
            color = PeeringColors.ink,
            modifier = Modifier.weight(1f),
        )
        Text(
            stringResource(R.string.commit_title),
            style = PeeringText.subheadlineSemibold,
            color = if (canCommit) PeeringColors.accent else PeeringColors.tertiary,
            modifier = Modifier
                .clickable(enabled = canCommit, role = Role.Button, onClick = onCommit)
                .padding(horizontal = 16.dp, vertical = 14.dp),
        )
    }
}

@Composable
private fun ChangeList(ui: ChangesUi, onOpen: (String) -> Unit, modifier: Modifier) {
    LazyColumn(modifier, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 28.dp)) {
        item(key = "summary") { Summary(ui) }
        when {
            ui.waiting -> item(key = "waiting") { Waiting() }
            ui.entries.isEmpty() -> item(key = "empty") {
                Text(
                    stringResource(R.string.changes_empty),
                    style = PeeringText.subheadline,
                    color = PeeringColors.muted,
                    modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
                )
            }
            else -> items(ui.entries, key = { it.path }) { entry ->
                if (entry != ui.entries.first()) HorizontalDivider(color = PeeringColors.hairline)
                EntryRow(entry, onClick = { onOpen(entry.path) })
            }
        }
    }
}

@Composable
private fun Summary(ui: ChangesUi) {
    OutlinedPanel(Modifier.fillMaxWidth().padding(bottom = 14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val title = if (ui.entries.isEmpty()) {
                stringResource(R.string.changes_none)
            } else {
                pluralStringResource(R.plurals.changes_count, ui.entries.size, ui.entries.size)
            }
            Text(title, style = PeeringText.headline, color = PeeringColors.ink, modifier = Modifier.weight(1f))
            DiffCounts(ui.added, ui.removed)
        }
        ui.message?.let { Text(it, style = PeeringText.caption, color = PeeringColors.muted, modifier = Modifier.padding(top = 6.dp)) }
        if (ui.truncated) {
            Text(stringResource(R.string.changes_truncated), style = PeeringText.caption, color = PeeringColors.muted, modifier = Modifier.padding(top = 6.dp))
        }
    }
}

@Composable
private fun Waiting() {
    Row(
        Modifier.fillMaxWidth().padding(top = 30.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(color = PeeringColors.ink.copy(alpha = 0.7f), strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Text(stringResource(R.string.changes_waiting), style = PeeringText.subheadline, color = PeeringColors.muted)
    }
}

@Composable
private fun EntryRow(entry: ChangeEntryUi, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(AppIcons.file, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(entry.name, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (entry.folder.isNotEmpty()) {
                Text(entry.folder, style = PeeringText.caption2Monospaced, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (entry.commentCount > 0) {
            Text("${entry.commentCount}", style = PeeringText.caption.copy(fontWeight = FontWeight.Bold), color = PeeringColors.accent)
        }
        DiffCounts(entry.added, entry.removed)
        Text(
            kindMarker(entry.kind),
            style = PeeringText.caption.copy(fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace),
            color = PeeringColors.muted,
            modifier = Modifier.size(12.dp),
        )
    }
}

internal fun kindMarker(kind: AgentChangeKind): String = when (kind) {
    AgentChangeKind.MODIFIED -> "M"
    AgentChangeKind.ADDED -> "A"
    AgentChangeKind.DELETED -> "D"
    AgentChangeKind.UNTRACKED -> "U"
}

@Composable
private fun BottomBar(commentCount: Int, onRefresh: () -> Unit, onSend: () -> Unit) {
    Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
        if (commentCount > 0) {
            InkButton(onClick = onSend, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                Icon(AgentIcons.sendPlane, contentDescription = null, modifier = Modifier.size(18.dp))
                Text(
                    pluralStringResource(R.plurals.changes_send_comments, commentCount, commentCount),
                    style = PeeringText.subheadlineSemibold,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
        IconButton(onClick = onRefresh, modifier = Modifier.align(Alignment.End)) {
            Icon(AppIcons.refresh, contentDescription = stringResource(R.string.changes_refresh), tint = PeeringColors.ink)
        }
    }
}

/** The Changes screen over a chat, with its presenters tied to that chat. */
@Composable
fun ChangesOverlay(port: AgentsPort, sessionID: String, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val changes = remember(sessionID) { ChangesPresenter(port, sessionID, scope) }
    val commit = remember(sessionID) { CommitPresenter(port, sessionID, scope) }
    ChangesScreen(changes, commit, onClose = onClose)
}
