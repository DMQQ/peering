package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.NoteAdd
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.RemoteEntryKind

/** The one filled control of the list: a menu to make a folder or a file, or to send documents from the phone. */
@Composable
fun NewEntryButton(enabled: Boolean, presenter: FileListPresenter, onUpload: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        FloatingActionButton(
            onClick = { if (enabled) open = true },
            containerColor = if (enabled) PeeringColors.ink else PeeringColors.containerHighest,
            contentColor = if (enabled) PeeringColors.onInk else PeeringColors.faint,
        ) {
            Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.files_new))
        }
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
            PeeringMenuItem(
                title = stringResource(R.string.files_upload),
                icon = Icons.Outlined.UploadFile,
                onClick = {
                    open = false
                    onUpload()
                },
            )
        }
    }
}
