package pl.dmq.peering.feature.files

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.RemoteDirectoryEntry

@Composable
fun FileEntryRow(entry: RemoteDirectoryEntry, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = MaterialTheme.shapes.small
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(PeeringColors.surface)
            .border(1.dp, PeeringColors.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(entry.name, style = MaterialTheme.typography.titleSmall, color = PeeringColors.ink, maxLines = 1)
            Text(
                detailText(entry),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun detailText(entry: RemoteDirectoryEntry): String = when (FileEntryKind.of(entry)) {
    FileEntryKind.FOLDER -> stringResource(R.string.files_kind_folder)
    FileEntryKind.FOLDER_LINK -> stringResource(R.string.files_kind_folder_link)
    FileEntryKind.LINK -> stringResource(R.string.files_kind_link)
    FileEntryKind.EXECUTABLE -> stringResource(R.string.files_kind_executable, fileSizeLabel(entry.size))
    FileEntryKind.FILE -> fileSizeLabel(entry.size)
}
