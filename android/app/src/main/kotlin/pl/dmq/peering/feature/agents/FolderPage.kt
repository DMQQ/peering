package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlIcon
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

private val recentLimit = 3

/**
 * The page after "Chat with": the computer's folders one level at a time, recent folders at the top of home, and a bar
 * at the bottom with the search, the hidden-folders switch and "Use".
 */
@Composable
fun FolderPage(
    folders: FolderPicker,
    recentFolders: List<String>,
    onUseFolder: () -> Unit,
    onUseRecent: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by folders.ui.collectAsState()
    val atHome = ui.path != null && ui.parentPath == null
    val name = ui.path?.let(FilePath::name) ?: stringResource(R.string.agents_choose_folder_title)
    Column(modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.agents_back), tint = PeeringColors.ink)
            }
            Text(name, style = PeeringText.subheadlineSemibold.copy(fontSize = 17.sp), color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        LazyColumn(Modifier.weight(1f)) {
            ui.waitingNote?.let { note -> item(key = "waiting") { Note(note, PeeringColors.muted, AppIcons.computer) } }
            ui.failure?.let { failure -> item(key = "failure") { Note(failure, PeeringColors.danger, null) } }
            if (atHome && !ui.isLoading) {
                val recents = recentFolders.filter { it != ui.path }.take(recentLimit)
                if (recents.isNotEmpty()) item(key = "recents") { RecentFolders(recents, onUseRecent) }
            }
            if (ui.parentPath != null) item(key = "up") { UpRow(folders::up) }
            if (!ui.isLoading && ui.folders.isEmpty() && ui.failure == null) {
                item(key = "empty") {
                    val text = if (ui.query.isEmpty()) stringResource(R.string.agents_folder_empty) else stringResource(R.string.agents_folder_no_match, ui.query)
                    Note(text, PeeringColors.muted, null)
                }
            }
            items(ui.folders, key = { it.name }) { folder ->
                if (folder != ui.folders.first()) HorizontalDivider(color = PeeringColors.hairline)
                FolderRow(folder.name) { folders.enter(folder) }
            }
            item(key = "footer") { Footer(ui.path.orEmpty(), ui.isTruncated) }
        }
        FolderBar(ui, folders, onUseFolder)
    }
}

@Composable
private fun Note(text: String, color: Color, icon: ImageVector?) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (icon != null) Icon(icon, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
        Text(text, style = PeeringText.footnote, color = color)
    }
    HorizontalDivider(color = PeeringColors.hairline)
}

@Composable
private fun FolderRow(name: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        ControlIcon(AppIcons.folder)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, style = PeeringText.subheadlineMedium, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(stringResource(R.string.agents_folder_kind), style = PeeringText.caption, color = PeeringColors.muted)
        }
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun UpRow(onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        ControlIcon(AgentIcons.upLeft)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("..", style = PeeringText.subheadlineMedium.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.ink)
            Text(stringResource(R.string.agents_up_one_level), style = PeeringText.caption, color = PeeringColors.muted)
        }
    }
    HorizontalDivider(color = PeeringColors.hairline)
}

@Composable
private fun RecentFolders(paths: List<String>, onUse: (String) -> Unit) {
    Column {
        SectionLabel(stringResource(R.string.agents_recent_folders), AgentIcons.history, Modifier.padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 6.dp))
        paths.forEachIndexed { index, path ->
            if (index > 0) HorizontalDivider(color = PeeringColors.hairline)
            Row(
                Modifier.fillMaxWidth().clickable(role = Role.Button) { onUse(path) }.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(11.dp),
            ) {
                ControlIcon(AgentIcons.history)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        path,
                        style = PeeringText.footnote.copy(fontFamily = FontFamily.Monospace),
                        color = PeeringColors.ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(stringResource(R.string.agents_work_here_again), style = PeeringText.caption, color = PeeringColors.muted)
                }
                Icon(AgentIcons.turnRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
            }
        }
        HorizontalDivider(Modifier.padding(top = 14.dp), color = PeeringColors.hairline)
    }
}

@Composable
private fun Footer(path: String, truncated: Boolean) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            path,
            style = PeeringText.caption2Monospaced,
            color = PeeringColors.tertiary,
            maxLines = 1,
            overflow = TextOverflow.Clip,
            modifier = Modifier.padding(bottom = 2.dp),
        )
        Text(stringResource(R.string.agents_folder_hint), style = PeeringText.caption, color = PeeringColors.muted)
        if (truncated) Text(stringResource(R.string.agents_folder_truncated), style = PeeringText.caption, color = PeeringColors.faint)
    }
}
