package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Column
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
import pl.dmq.peering.ui.theme.PeeringText

/** Asks for a prompt to keep. Save is off while the field is blank. */
@Composable
fun SaveTemplateDialog(onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_template_save_title)) },
        text = {
            Column {
                PeeringTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = stringResource(R.string.agents_template_field),
                    singleLine = false,
                )
                Text(stringResource(R.string.agents_template_message), style = PeeringText.footnote, color = PeeringColors.muted)
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(text) }, enabled = text.isNotBlank()) {
                Text(stringResource(R.string.agents_rename_save), color = if (text.isNotBlank()) PeeringColors.accent else PeeringColors.tertiary)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.agents_cancel), color = PeeringColors.accent) } },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
    )
}
