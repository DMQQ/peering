package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
internal fun RenameDialog(current: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = PeeringColors.sheet,
        title = { Text(stringResource(R.string.connect_rename_title)) },
        text = {
            Column {
                Text(stringResource(R.string.connect_rename_text), color = PeeringColors.muted)
                Spacer(Modifier.height(16.dp))
                PeeringTextField(name, { name = it }, stringResource(R.string.connect_rename_hint), Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(onClick = { onSave(name) }) { Text(stringResource(R.string.connect_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.connect_cancel)) } },
    )
}
