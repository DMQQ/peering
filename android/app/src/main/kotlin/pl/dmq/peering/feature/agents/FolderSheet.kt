package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun FolderSheet(
    folders: FolderPicker,
    recentFolders: List<String>,
    onUseFolder: () -> Unit,
    onBack: () -> Unit,
    onDismiss: () -> Unit,
) {
    val ui by folders.ui.collectAsState()
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.agents_choose_folder_title)) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.agents_folder_hint), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
            Text(ui.path.orEmpty(), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, maxLines = 2)
            ui.waitingNote?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted) }
            ui.failure?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.danger) }
        }
        if (recentFolders.isNotEmpty()) {
            Text(
                stringResource(R.string.agents_recent_folders),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp),
            )
            recentFolders.forEach { path -> FolderItem(name = path, onClick = { folders.open(path) }) }
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PeeringTextField(
                value = ui.query,
                onValueChange = folders::setQuery,
                label = stringResource(R.string.agents_search_folders),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(stringResource(R.string.agents_show_hidden), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
                Switch(checked = ui.showsHidden, onCheckedChange = folders::setShowsHidden)
            }
        }
        LazyColumn(modifier = Modifier.height(260.dp)) {
            if (ui.parentPath != null) {
                item(key = "up") { FolderItem(name = stringResource(R.string.agents_up_one_level), onClick = folders::up) }
            }
            items(ui.folders, key = { it.name }) { folder -> FolderItem(name = folder.name, onClick = { folders.enter(folder) }) }
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!ui.isLoading && ui.folders.isEmpty()) {
                Text(stringResource(R.string.agents_folder_empty), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
            }
            if (ui.isTruncated) {
                Text(stringResource(R.string.agents_folder_truncated), style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint)
            }
            PrimaryButton(title = stringResource(R.string.agents_use_folder), onClick = onUseFolder, enabled = ui.usablePath != null)
            LinkButton(title = stringResource(R.string.agents_back), onClick = onBack, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun FolderItem(name: String, onClick: () -> Unit) {
    PeeringListItem(
        headline = name,
        onClick = onClick,
        role = Role.Button,
        bleed = false,
        leading = { Icon(AppIcons.folder, contentDescription = null) },
    )
}
