package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors

/** The dialog the list has open, if any. */
@Composable
fun FileDialogHost(dialog: FileDialog?, presenter: FileListPresenter) {
    when (dialog) {
        null -> Unit
        is FileDialog.Name -> NameDialog(dialog, presenter)
        is FileDialog.ConfirmDelete -> DeleteDialog(dialog, presenter)
        is FileDialog.ConfirmRun -> RunDialog(dialog, presenter)
    }
}

@Composable
private fun NameDialog(dialog: FileDialog.Name, presenter: FileListPresenter) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val title = when (dialog.purpose) {
        FileDialog.Purpose.NEW_FOLDER -> R.string.files_new_folder
        FileDialog.Purpose.NEW_FILE -> R.string.files_new_file
        FileDialog.Purpose.RENAME -> R.string.files_rename
    }
    val confirm = if (dialog.purpose == FileDialog.Purpose.RENAME) R.string.files_rename else R.string.files_create
    AlertDialog(
        onDismissRequest = presenter::dismissDialog,
        title = { Text(stringResource(title)) },
        text = { NameDialogField(dialog, presenter, focus) },
        confirmButton = { TextButton(onClick = presenter::confirmName) { Text(stringResource(confirm), color = PeeringColors.accent) } },
        dismissButton = {
            TextButton(onClick = presenter::dismissDialog) { Text(stringResource(R.string.files_cancel), color = PeeringColors.accent) }
        },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
        textContentColor = PeeringColors.muted,
        iconContentColor = Color.Unspecified,
    )
}

@Composable
private fun NameDialogField(dialog: FileDialog.Name, presenter: FileListPresenter, focus: FocusRequester) {
    Column {
        PeeringTextField(
            value = dialog.text,
            onValueChange = presenter::editName,
            label = stringResource(R.string.files_name_label),
            modifier = Modifier.focusRequester(focus),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { presenter.confirmName() }),
        )
        dialog.problem?.let {
            Text(
                stringResource(if (it == FileDialog.NameProblem.TAKEN) R.string.files_name_taken else R.string.files_name_invalid),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
        }
    }
}

@Composable
private fun DeleteDialog(dialog: FileDialog.ConfirmDelete, presenter: FileListPresenter) {
    val single = dialog.entries.singleOrNull()
    PeeringAlert(
        title = if (single != null) {
            stringResource(R.string.files_delete_title_one, single.name)
        } else {
            stringResource(R.string.files_delete_title_many, dialog.entries.size)
        },
        message = stringResource(if (dialog.includesFolder) R.string.files_delete_folder else R.string.files_delete_file),
        confirm = stringResource(if (dialog.includesFolder) R.string.files_delete_all else R.string.files_delete),
        onConfirm = presenter::confirmDelete,
        cancel = stringResource(R.string.files_cancel),
        onCancel = presenter::dismissDialog,
        destructive = true,
    )
}

@Composable
private fun RunDialog(dialog: FileDialog.ConfirmRun, presenter: FileListPresenter) {
    PeeringAlert(
        title = stringResource(R.string.files_run_title),
        message = stringResource(R.string.files_run_message, dialog.entry.name),
        confirm = stringResource(R.string.files_run),
        onConfirm = presenter::confirmRun,
        cancel = stringResource(R.string.files_cancel),
        onCancel = presenter::dismissDialog,
    )
}
