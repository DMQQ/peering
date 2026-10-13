package pl.dmq.peering.ui.kit

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import pl.dmq.peering.ui.theme.PeeringColors

/** Material's alert dialog: title, message, and a text button each for cancelling and confirming. */
@Composable
fun PeeringAlert(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    cancel: String,
    onCancel: () -> Unit,
    destructive: Boolean = false,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(confirm, color = if (destructive) PeeringColors.danger else PeeringColors.accent) }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(cancel, color = PeeringColors.accent) } },
        containerColor = PeeringColors.containerHigh,
        titleContentColor = PeeringColors.ink,
        textContentColor = PeeringColors.muted,
        iconContentColor = Color.Unspecified,
    )
}
