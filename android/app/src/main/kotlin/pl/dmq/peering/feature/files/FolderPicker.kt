package pl.dmq.peering.feature.files

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The folders of the computer under a path bar, with a button that returns the folder on screen through [onChoose].
 * Meant for a sheet or a screen of its own; the caller starts it with [FolderPickerPresenter.open].
 */
@Composable
fun FolderPicker(presenter: FolderPickerPresenter, onChoose: (String) -> Unit, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    Column(modifier = modifier.fillMaxSize()) {
        if (ui.breadcrumbs.isNotEmpty()) BreadcrumbBar(ui.breadcrumbs, onGoTo = presenter::goTo)
        when (ui.status) {
            FileListStatus.CONTENT -> LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
                items(ui.folders, key = { it }) { name ->
                    ListItem(
                        headlineContent = { Text(name, maxLines = 1) },
                        leadingContent = { Icon(AppIcons.folder, contentDescription = null) },
                        trailingContent = { Icon(AppIcons.chevronRight, contentDescription = null) },
                        modifier = Modifier.clickable(role = Role.Button) { presenter.enter(name) },
                        colors = ListItemDefaults.colors(
                            containerColor = Color.Transparent,
                            headlineColor = PeeringColors.ink,
                            leadingIconColor = PeeringColors.muted,
                            trailingIconColor = PeeringColors.muted,
                        ),
                    )
                }
            }
            else -> Column(modifier = Modifier.weight(1f).fillMaxWidth().padding(32.dp)) {
                EmptyState(
                    icon = AppIcons.folder,
                    title = ui.failure ?: stringResource(R.string.files_folders_only_empty),
                    body = "",
                )
            }
        }
        PrimaryButton(
            title = stringResource(R.string.files_choose_folder),
            onClick = { ui.path?.let(onChoose) },
            enabled = ui.path != null,
            modifier = Modifier.padding(16.dp),
        )
    }
}
