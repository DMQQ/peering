package pl.dmq.peering.feature.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors

/** The bottom bar of the folder page: search in this folder, show hidden folders, and "Use". */
@Composable
internal fun FolderBar(ui: FolderPickerUi, folders: FolderPicker, onUse: () -> Unit) {
    val folderName = ui.path?.let(FilePath::name) ?: stringResource(R.string.agents_choose_folder_title)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(PeeringColors.backdrop)
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PeeringTextField(
            value = ui.query,
            onValueChange = folders::setQuery,
            label = stringResource(R.string.agents_search_in, folderName),
            modifier = Modifier.weight(1f),
        )
        IconButton(
            onClick = { folders.setShowsHidden(!ui.showsHidden) },
            colors = IconButtonDefaults.iconButtonColors(contentColor = if (ui.showsHidden) PeeringColors.ink else PeeringColors.muted),
        ) {
            Icon(AppIcons.observe, contentDescription = stringResource(R.string.agents_show_hidden))
        }
        InkButton(onClick = onUse, enabled = ui.usablePath != null) { Text(stringResource(R.string.agents_use)) }
    }
}
