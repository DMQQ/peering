package pl.dmq.peering.feature.files

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.FileUpload
import androidx.compose.material.icons.outlined.NoteAdd
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.terminal.railPress
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuDivider
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.wire.RemoteEntryKind

private val BAR_HEIGHT = 48.dp

/**
 * The one bottom row of the folder browser, as on the iPhone: where you are above it, then new, a search field with the
 * hidden-files switch inside it, and send. A long press on the switch opens the order, which the iPhone does not offer.
 */
@Composable
fun FilesBottomBar(ui: FileListUi, presenter: FileListPresenter, onUpload: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxWidth().imePadding().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ui.path?.let { LocationLine(it) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            NewButton(ui.canChange, presenter)
            SearchCapsule(ui, presenter, Modifier.weight(1f))
            CircleButton(Icons.Outlined.FileUpload, stringResource(R.string.files_upload), ui.canChange, onUpload)
        }
    }
}

@Composable
private fun LocationLine(path: String) {
    Row(
        Modifier.padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(AppIcons.folder, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(12.dp))
        Text(
            headTruncated(path),
            color = PeeringColors.muted,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

@Composable
private fun CircleButton(icon: ImageVector, description: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(BAR_HEIGHT).railPress(onClick, enabled = enabled).sessionSurface(CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = description, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun NewButton(enabled: Boolean, presenter: FileListPresenter) {
    var open by remember { mutableStateOf(false) }
    Box {
        CircleButton(Icons.Outlined.Add, stringResource(R.string.files_new), enabled) { open = true }
        PeeringMenu(expanded = open, onDismiss = { open = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.files_new_folder),
                icon = Icons.Outlined.CreateNewFolder,
                onClick = {
                    open = false
                    presenter.beginCreate(RemoteEntryKind.FOLDER)
                },
            )
            PeeringMenuItem(
                title = stringResource(R.string.files_new_file),
                icon = Icons.Outlined.NoteAdd,
                onClick = {
                    open = false
                    presenter.beginCreate(RemoteEntryKind.FILE)
                },
            )
        }
    }
}

@Composable
private fun SearchCapsule(ui: FileListUi, presenter: FileListPresenter, modifier: Modifier) {
    Row(
        modifier.height(BAR_HEIGHT).sessionSurface(PillShape).padding(start = 14.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SessionIcons.search, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(16.dp))
        Box(Modifier.weight(1f)) {
            if (ui.query.isEmpty()) {
                Text(stringResource(R.string.files_search), color = PeeringColors.tertiary, fontSize = 16.sp, maxLines = 1)
            }
            BasicTextField(
                value = ui.query,
                onValueChange = presenter::setQuery,
                singleLine = true,
                textStyle = TextStyle(color = PeeringColors.ink, fontSize = 16.sp),
                cursorBrush = SolidColor(PeeringColors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (ui.query.isNotEmpty()) {
            Icon(
                SessionIcons.clearSearch,
                contentDescription = stringResource(R.string.files_clear_query),
                tint = PeeringColors.tertiary,
                modifier = Modifier.size(20.dp).railPress({ presenter.setQuery("") }, scale = 0.9f),
            )
        }
        HiddenSwitch(ui, presenter)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HiddenSwitch(ui: FileListUi, presenter: FileListPresenter) {
    var orderOpen by remember { mutableStateOf(false) }
    Box(
        Modifier.width(36.dp).height(BAR_HEIGHT - 12.dp).combinedClickable(
            role = Role.Switch,
            onLongClick = { orderOpen = true },
            onLongClickLabel = stringResource(R.string.files_sort),
            onClick = presenter::toggleHidden,
        ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (ui.showsHidden) AppIcons.observe else Icons.Outlined.VisibilityOff,
            contentDescription = stringResource(R.string.files_show_hidden),
            tint = if (ui.showsHidden) PeeringColors.accent else PeeringColors.muted,
            modifier = Modifier.size(18.dp),
        )
        SortMenu(orderOpen, ui.sort, presenter) { orderOpen = false }
    }
}

@Composable
private fun SortMenu(expanded: Boolean, current: FileSort, presenter: FileListPresenter, onDismiss: () -> Unit) {
    PeeringMenu(expanded = expanded, onDismiss = onDismiss) {
        FileSort.entries.forEach { order ->
            PeeringMenuItem(
                title = stringResource(sortLabel(order)),
                selected = order == current,
                onClick = {
                    presenter.setSort(order)
                    onDismiss()
                },
            )
        }
        PeeringMenuDivider()
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
