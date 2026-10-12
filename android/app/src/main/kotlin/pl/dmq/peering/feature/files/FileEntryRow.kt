package pl.dmq.peering.feature.files

import android.text.format.DateUtils
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * One entry of a folder as a two line list item: a type icon (a check while selected), its name, and its mode,
 * size and date. A tap opens it, or toggles it while a selection is going; a long press starts one.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FileEntryRow(row: FileRowUi, onClick: () -> Unit, onLongClick: () -> Unit, modifier: Modifier = Modifier) {
    ListItem(
        headlineContent = { Text(row.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(detailText(row), maxLines = 1) },
        leadingContent = { RowIcon(row) },
        modifier = modifier
            .combinedClickable(role = Role.Button, onClick = onClick, onLongClick = onLongClick),
        colors = ListItemDefaults.colors(
            containerColor = if (row.isSelected) PeeringColors.selectedIndicator.copy(alpha = 0.5f) else Color.Transparent,
            headlineColor = PeeringColors.ink,
            supportingColor = PeeringColors.muted,
        ),
    )
}

@Composable
private fun RowIcon(row: FileRowUi) {
    val tint = if (row.isSelected) PeeringColors.accent else PeeringColors.ink.copy(alpha = 0.12f)
    Box(modifier = Modifier.size(40.dp).background(tint, CircleShape), contentAlignment = Alignment.Center) {
        Icon(
            imageVector = if (row.isSelected) AppIcons.check else row.glyph.icon,
            contentDescription = null,
            tint = if (row.isSelected) PeeringColors.ink else PeeringColors.muted,
            modifier = Modifier.size(24.dp),
        )
    }
}

@Composable
private fun detailText(row: FileRowUi): String {
    val context = LocalContext.current
    val entry = row.entry
    val size = if (entry.isDirectory) null else fileSizeLabel(entry.size)
    val date = remember(row.modifiedEpochMillis) {
        row.modifiedEpochMillis?.let { DateUtils.formatDateTime(context, it, DATE_FLAGS) }
    }
    val kind = when {
        entry.isSymlink && entry.isDirectory -> stringResource(R.string.files_folder_link)
        entry.isSymlink -> stringResource(R.string.files_detail_link)
        else -> size
    }
    return listOfNotNull(entry.permissions.takeIf { it.isNotEmpty() }, kind, date).joinToString(" · ")
}

private const val DATE_FLAGS = DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_YEAR
