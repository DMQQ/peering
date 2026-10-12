package pl.dmq.peering.feature.agents

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderSheet(
    folders: FolderPicker,
    recentFolders: List<String>,
    onUseFolder: () -> Unit,
    onBack: () -> Unit,
    onDismiss: () -> Unit,
) {
    val ui by folders.ui.collectAsState()
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = PeeringColors.backdrop) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.agents_choose_folder_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.agents_folder_hint), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
            Text(ui.path.orEmpty(), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted, maxLines = 2)
            ui.waitingNote?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted) }
            ui.failure?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.danger) }
            if (recentFolders.isNotEmpty()) {
                Text(stringResource(R.string.agents_recent_folders), style = MaterialTheme.typography.labelLarge, color = PeeringColors.muted)
                recentFolders.forEach { path ->
                    Text(
                        path,
                        style = MaterialTheme.typography.bodyMedium,
                        color = PeeringColors.ink,
                        maxLines = 1,
                        modifier = Modifier.fillMaxWidth().clickable { folders.open(path) }.padding(vertical = 6.dp),
                    )
                }
            }
            OutlinedTextField(
                value = ui.query,
                onValueChange = folders::setQuery,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text(stringResource(R.string.agents_search_folders)) },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(stringResource(R.string.agents_show_hidden), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
                Switch(checked = ui.showsHidden, onCheckedChange = folders::setShowsHidden)
            }
            LazyColumn(modifier = Modifier.height(260.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (ui.parentPath != null) {
                    item(key = "up") {
                        Text(
                            stringResource(R.string.agents_up_one_level),
                            style = MaterialTheme.typography.titleSmall,
                            color = PeeringColors.muted,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(onClick = folders::up)
                                .padding(vertical = 10.dp),
                        )
                    }
                }
                items(ui.folders, key = { it.name }) { folder ->
                    Text(
                        folder.name,
                        style = MaterialTheme.typography.titleSmall,
                        color = PeeringColors.ink,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { folders.enter(folder) }
                            .padding(vertical = 10.dp),
                    )
                }
            }
            if (!ui.isLoading && ui.folders.isEmpty()) {
                Text(stringResource(R.string.agents_folder_empty), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
            }
            if (ui.isTruncated) {
                Text(stringResource(R.string.agents_folder_truncated), style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint)
            }
            Button(
                onClick = onUseFolder,
                enabled = ui.usablePath != null,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
            ) {
                Text(stringResource(R.string.agents_use_folder), style = MaterialTheme.typography.labelLarge)
            }
            Text(
                stringResource(R.string.agents_back),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = onBack).padding(vertical = 8.dp),
            )
        }
    }
}
