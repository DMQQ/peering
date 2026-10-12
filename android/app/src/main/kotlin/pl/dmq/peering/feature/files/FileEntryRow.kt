package pl.dmq.peering.feature.files

import android.text.format.DateUtils
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** One entry of a folder as a two line list item: a glyph for what it is, its name, then its size or kind and its date. */
@Composable
fun FileEntryRow(entry: RemoteDirectoryEntry, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val glyph = FileGlyph.of(entry)
    PeeringListItem(
        headline = entry.name,
        supporting = detailText(entry),
        onClick = onClick,
        role = Role.Button,
        bleed = false,
        modifier = modifier,
        leading = { IconTile(glyph.icon(), size = 40.dp, tint = if (glyph == FileGlyph.FOLDER) PeeringColors.accent else PeeringColors.ink) },
        trailing = if (entry.isDirectory) {
            { Icon(AppIcons.chevronRight, contentDescription = null) }
        } else {
            null
        },
    )
}

private fun FileGlyph.icon(): ImageVector = when (this) {
    FileGlyph.FOLDER -> AppIcons.folder
    FileGlyph.LINK -> AppIcons.openExternal
    FileGlyph.EXECUTABLE -> AppIcons.power
    FileGlyph.IMAGE -> AppIcons.image
    FileGlyph.CODE -> AppIcons.code
    FileGlyph.ARCHIVE -> AppIcons.archive
    FileGlyph.DOCUMENT -> AppIcons.document
    FileGlyph.FILE -> AppIcons.file
}

@Composable
private fun detailText(entry: RemoteDirectoryEntry): String {
    val what = when (FileEntryKind.of(entry)) {
        FileEntryKind.FOLDER -> stringResource(R.string.files_kind_folder)
        FileEntryKind.FOLDER_LINK -> stringResource(R.string.files_kind_folder_link)
        FileEntryKind.LINK -> stringResource(R.string.files_kind_link)
        FileEntryKind.EXECUTABLE -> stringResource(R.string.files_kind_executable, fileSizeLabel(entry.size))
        FileEntryKind.FILE -> fileSizeLabel(entry.size)
    }
    val context = LocalContext.current
    val date = entry.modifiedEpochMillis()?.let {
        DateUtils.formatDateTime(context, it, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_YEAR)
    }
    return if (date == null) what else stringResource(R.string.files_detail_with_date, what, date)
}
