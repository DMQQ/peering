package pl.dmq.peering.feature.files

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SelectAll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuDivider
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun barColors() = TopAppBarDefaults.topAppBarColors(
    containerColor = Color.Transparent,
    titleContentColor = PeeringColors.ink,
    navigationIconContentColor = PeeringColors.ink,
    actionIconContentColor = PeeringColors.ink,
)

/** The folder's name, a way up unless [onBack] is null, search, and a menu for the order and the hidden files. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderTopBar(ui: FileListUi, presenter: FileListPresenter, onBack: (() -> Unit)?, onSearch: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text(ui.path?.let(FilePath::name) ?: stringResource(R.string.hub_files), maxLines = 1) },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) { Icon(AppIcons.back, contentDescription = stringResource(R.string.files_back)) }
            }
        },
        actions = {
            IconButton(onClick = onSearch) {
                Icon(Icons.Outlined.Search, contentDescription = stringResource(R.string.files_search))
            }
            IconButton(onClick = { menuOpen = true }) {
                Icon(AppIcons.more, contentDescription = stringResource(R.string.files_more))
                SortMenu(menuOpen, ui, presenter) { menuOpen = false }
            }
        },
        colors = barColors(),
    )
}

@Composable
private fun SortMenu(expanded: Boolean, ui: FileListUi, presenter: FileListPresenter, onDismiss: () -> Unit) {
    PeeringMenu(expanded = expanded, onDismiss = onDismiss) {
        FileSort.entries.forEach { order ->
            PeeringMenuItem(
                title = stringResource(sortLabel(order)),
                selected = order == ui.sort,
                onClick = {
                    presenter.setSort(order)
                    onDismiss()
                },
            )
        }
        PeeringMenuDivider()
        PeeringMenuItem(
            title = stringResource(R.string.files_show_hidden),
            icon = AppIcons.observe,
            selected = ui.showsHidden,
            onClick = {
                presenter.toggleHidden()
                onDismiss()
            },
        )
        PeeringMenuItem(
            title = stringResource(R.string.files_refresh),
            icon = AppIcons.refresh,
            onClick = {
                presenter.refresh()
                onDismiss()
            },
        )
    }
}

private fun sortLabel(order: FileSort): Int = when (order) {
    FileSort.NAME -> R.string.files_sort_name
    FileSort.SIZE -> R.string.files_sort_size
    FileSort.MODIFIED -> R.string.files_sort_modified
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

/** The search field in the bar's place. Closing it clears the filter. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchTopBar(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    TopAppBar(
        title = {
            TextField(
                value = query,
                onValueChange = onQuery,
                modifier = Modifier.focusRequester(focus),
                singleLine = true,
                placeholder = { Text(stringResource(R.string.files_search), color = PeeringColors.muted) },
                textStyle = MaterialTheme.typography.bodyLarge,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    cursorColor = PeeringColors.accent,
                ),
            )
        },
        navigationIcon = {
            IconButton(onClick = onClose) { Icon(AppIcons.back, contentDescription = stringResource(R.string.files_close_search)) }
        },
        actions = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQuery("") }) {
                    Icon(AppIcons.close, contentDescription = stringResource(R.string.files_clear_query))
                }
            }
        },
        colors = barColors(),
    )
}
