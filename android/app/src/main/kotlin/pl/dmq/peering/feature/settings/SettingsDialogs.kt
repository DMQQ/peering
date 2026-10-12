package pl.dmq.peering.feature.settings

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
internal fun ForgetConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = PeeringColors.backdrop,
        title = { Text(stringResource(R.string.settings_forget_title)) },
        text = { Text(stringResource(R.string.settings_forget_text)) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.settings_forget_confirm), color = PeeringColors.danger)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.settings_cancel), color = PeeringColors.ink)
            }
        },
    )
}
