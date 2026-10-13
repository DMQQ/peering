package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors

/** Cancel comes first and keeps the shell: a stray tap must not land on the destructive answer. */
@Composable
fun EndTerminalPrompt(tab: TerminalTab, onEnd: () -> Unit, onKeep: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.terminal_end_title, tab.name),
        message = stringResource(R.string.terminal_end_detail),
        confirm = stringResource(R.string.terminal_end),
        onConfirm = onEnd,
        cancel = stringResource(R.string.terminal_keep),
        onCancel = onKeep,
        destructive = true,
    )
}

/** An alert with a Name field; an empty name is not saved. */
@Composable
fun RenameTerminalDialog(tab: TerminalTab, onSave: (String) -> Unit, onCancel: () -> Unit) {
    var name by remember(tab.id) { mutableStateOf(tab.name) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.terminal_rename)) },
        text = {
            PeeringTextField(value = name, onValueChange = { name = it }, label = stringResource(R.string.terminal_rename_name), modifier = Modifier.fillMaxWidth())
        },
        confirmButton = {
            TextButton(onClick = { onSave(name.trim()) }, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.terminal_save), color = PeeringColors.accent)
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.terminal_cancel), color = PeeringColors.accent) } },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
        textContentColor = PeeringColors.muted,
    )
}
