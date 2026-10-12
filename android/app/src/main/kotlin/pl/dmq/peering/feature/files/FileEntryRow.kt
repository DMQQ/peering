package pl.dmq.peering.feature.files

import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** One entry of a folder as a two line list item: a folder or file glyph, its name, and its kind or size. */
@Composable
fun FileEntryRow(entry: RemoteDirectoryEntry, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val kind = FileEntryKind.of(entry)
    val isFolder = kind == FileEntryKind.FOLDER || kind == FileEntryKind.FOLDER_LINK
    PeeringListItem(
        headline = entry.name,
        supporting = detailText(entry),
        onClick = onClick,
        role = Role.Button,
        bleed = false,
        modifier = modifier,
        leading = { Icon(if (isFolder) AppIcons.folder else AppIcons.file, contentDescription = null) },
    )
}

@Composable
private fun detailText(entry: RemoteDirectoryEntry): String = when (FileEntryKind.of(entry)) {
    FileEntryKind.FOLDER -> stringResource(R.string.files_kind_folder)
    FileEntryKind.FOLDER_LINK -> stringResource(R.string.files_kind_folder_link)
    FileEntryKind.LINK -> stringResource(R.string.files_kind_link)
    FileEntryKind.EXECUTABLE -> stringResource(R.string.files_kind_executable, fileSizeLabel(entry.size))
    FileEntryKind.FILE -> fileSizeLabel(entry.size)
}
