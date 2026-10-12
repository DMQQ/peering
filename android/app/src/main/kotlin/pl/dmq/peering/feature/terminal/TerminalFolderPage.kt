package pl.dmq.peering.feature.terminal

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.files.FolderPicker
import pl.dmq.peering.feature.files.FolderPickerPresenter
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private const val RECENT_ROWS = 3

/**
 * The page after "New terminal": the computer's folders one level at a time, the folders earlier terminals started in
 * above them, and "Use this folder" at the bottom. System back climbs a folder, then leaves the page.
 */
@Composable
fun TerminalFolderPage(
    folders: FolderPickerPresenter,
    recents: FolderRecents,
    onChoose: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(folders) { folders.open() }
    BackHandler { if (!folders.up()) onBack() }
    val shown by folders.ui.collectAsState()
    val recentPaths by recents.paths.collectAsState()
    val offered = recentPaths.filter { it != shown.path }.take(RECENT_ROWS)
    Column(modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.terminal_back), tint = PeeringColors.ink)
            }
            Text(
                stringResource(R.string.terminal_new),
                style = PeeringText.subheadlineSemibold.copy(fontSize = 17.sp),
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (offered.isNotEmpty()) {
            Text(
                stringResource(R.string.terminal_folder_recents),
                style = PeeringText.footnote,
                color = PeeringColors.muted,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
            offered.forEach { path -> RecentRow(path) { onChoose(path) } }
        }
        FolderPicker(folders, onChoose, Modifier.weight(1f))
    }
}

@Composable
private fun RecentRow(path: String, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(FilePath.name(path), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(path, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = { Icon(AppIcons.folder, contentDescription = null) },
        modifier = Modifier.clickable(role = Role.Button, onClick = onClick),
        colors = ListItemDefaults.colors(
            containerColor = Color.Transparent,
            headlineColor = PeeringColors.ink,
            supportingColor = PeeringColors.muted,
            leadingIconColor = PeeringColors.muted,
        ),
    )
}
