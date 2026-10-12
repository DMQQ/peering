package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.ControlRow
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * Takes a computer's device ID typed or pasted, or scanned. An error shows only once the user has submitted something
 * the app refused (typing clears it), never on the empty field. [onScan] null hides the scan row.
 */
@Composable
fun HostIdEntrySheet(
    state: HostIdEntryState,
    onTextChanged: (String) -> Unit,
    onSubmit: () -> Unit,
    onScan: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    PeeringSheet(onDismiss) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text(stringResource(R.string.pairing_entry_heading), style = MaterialTheme.typography.headlineMedium, color = PeeringColors.ink)
            ControlsCard(stringResource(R.string.pairing_entry_card), footer = stringResource(R.string.pairing_entry_detail)) {
                PeeringTextField(
                    value = state.text,
                    onValueChange = onTextChanged,
                    label = stringResource(R.string.pairing_entry_hint),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = false,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { onSubmit() }),
                    monospaced = true,
                )
                ControlsDivider()
                ControlRow(stringResource(R.string.pairing_entry_paste), AppIcons.copy, Modifier.tappable({ clipboard.getText()?.text?.let(onTextChanged) }))
                if (onScan != null) {
                    ControlsDivider()
                    ControlRow(stringResource(R.string.pairing_entry_scan), AppIcons.qrScanner, Modifier.tappable(onScan))
                }
            }
            state.error?.let { Text(stringResource(it.messageRes()), style = PeeringText.caption, color = PeeringColors.danger) }
            PrimaryButton(stringResource(R.string.pairing_entry_submit), onClick = onSubmit, enabled = state.canSubmit)
        }
    }
}
