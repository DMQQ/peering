package pl.dmq.peering.feature.files

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.SelectAll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun barColors() = TopAppBarDefaults.topAppBarColors(
    containerColor = Color.Transparent,
    titleContentColor = PeeringColors.ink,
    navigationIconContentColor = PeeringColors.ink,
    actionIconContentColor = PeeringColors.ink,
)

/** The folder's name and a way up, for a page that is not under the hub's switcher. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderTopBar(ui: FileListUi, onBack: () -> Unit) {
    TopAppBar(
        title = { Text(ui.path?.let(FilePath::name) ?: stringResource(R.string.hub_files), maxLines = 1) },
        navigationIcon = {
            IconButton(onClick = onBack) { Icon(AppIcons.back, contentDescription = stringResource(R.string.files_back)) }
        },
        colors = barColors(),
    )
}

/** The count picked, and what can be done to them: all of them, one by itself (download, rename), or delete. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SelectionTopBar(ui: FileListUi, presenter: FileListPresenter) {
    TopAppBar(
        title = { Text(stringResource(R.string.files_selected, ui.selectedCount)) },
        navigationIcon = {
            IconButton(onClick = presenter::clearSelection) {
                Icon(AppIcons.close, contentDescription = stringResource(R.string.files_clear_selection))
            }
        },
        actions = {
            IconButton(onClick = presenter::selectAll) {
                Icon(Icons.Outlined.SelectAll, contentDescription = stringResource(R.string.files_select_all))
            }
            if (ui.selectedCount == 1) {
                IconButton(onClick = presenter::downloadSelected) {
                    Icon(AppIcons.download, contentDescription = stringResource(R.string.files_download))
                }
                IconButton(onClick = { presenter.selectedEntries().singleOrNull()?.let(presenter::beginRename) }, enabled = ui.canChange) {
                    Icon(Icons.Outlined.DriveFileRenameOutline, contentDescription = stringResource(R.string.files_rename))
                }
            }
            IconButton(onClick = presenter::beginDeleteSelected, enabled = ui.canChange) {
                Icon(AppIcons.delete, contentDescription = stringResource(R.string.files_delete))
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = PeeringColors.containerHigh,
            titleContentColor = PeeringColors.ink,
            navigationIconContentColor = PeeringColors.ink,
            actionIconContentColor = PeeringColors.ink,
        ),
    )
}
