package pl.dmq.peering.feature.agents

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors

/** A name for a chat, kept on this phone. Save is off while the field is blank. */
@Composable
fun RenameDialog(initial: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_rename)) },
        text = { PeeringTextField(value = name, onValueChange = { name = it }, label = stringResource(R.string.agents_rename_field)) },
        confirmButton = {
            TextButton(onClick = { onSave(name) }, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.agents_rename_save), color = if (name.isNotBlank()) PeeringColors.accent else PeeringColors.tertiary)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.agents_cancel), color = PeeringColors.accent) } },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
    )
}
