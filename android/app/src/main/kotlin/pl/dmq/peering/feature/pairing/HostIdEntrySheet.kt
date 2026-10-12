package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.InkButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.QuietButton

/**
 * Takes a Mac's device ID typed or pasted. An error shows only once the user has submitted something the app
 * refused (typing clears it), never on the empty field. [onScan] null hides the scan button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostIdEntrySheet(
    state: HostIdEntryState,
    onTextChanged: (String) -> Unit,
    onSubmit: () -> Unit,
    onScan: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = PeeringColors.sheet,
        contentWindowInsets = { WindowInsets(0, 0, 0, 0) },
        contentColor = PeeringColors.ink,
        shape = MaterialTheme.shapes.large.copy(bottomStart = CornerSize(0.dp), bottomEnd = CornerSize(0.dp)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 20.dp).imePadding().navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text = stringResource(R.string.pairing_entry_heading),
                style = MaterialTheme.typography.headlineSmall,
                color = PeeringColors.ink,
            )
            Text(
                text = stringResource(R.string.pairing_entry_detail),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
            OutlinedTextField(
                value = state.text,
                onValueChange = onTextChanged,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(stringResource(R.string.pairing_entry_hint)) },
                isError = state.error != null,
                supportingText = state.error?.let { error -> { Text(stringResource(error.messageRes())) } },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onSubmit() }),
                colors = peeringFieldColors(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                InkButton(onClick = onSubmit, enabled = state.canSubmit, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.pairing_entry_submit))
                }
                if (onScan != null) {
                    QuietButton(onClick = onScan, modifier = Modifier.weight(1.4f)) {
                        Icon(Icons.Filled.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text(stringResource(R.string.pairing_entry_scan), modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
        }
    }
}
