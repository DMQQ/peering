package pl.dmq.peering.feature.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.inkButtonColors

/** Takes a Mac's device ID typed, pasted or scanned. [onScanRequested] null hides the scan button. */
@Composable
fun HostIdEntryPanel(
    presenter: HostIdEntryPresenter,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)? = null,
) {
    val state by presenter.state.collectAsState()
    OutlinedPanel(modifier = modifier.fillMaxWidth()) {
        Text(
            text = stringResource(R.string.pairing_entry_heading),
            style = MaterialTheme.typography.titleMedium,
            color = PeeringColors.ink,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = stringResource(R.string.pairing_entry_detail),
            style = MaterialTheme.typography.bodySmall,
            color = PeeringColors.muted,
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = state.text,
            onValueChange = presenter::onTextChanged,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(stringResource(R.string.pairing_entry_hint)) },
            isError = state.error != null,
            supportingText = {
                state.error?.let { Text(stringResource(it.messageRes())) }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { presenter.submit() }),
            colors = peeringFieldColors(),
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = presenter::submit,
                enabled = state.canSubmit,
                colors = inkButtonColors(),
            ) {
                Text(stringResource(R.string.pairing_entry_submit))
            }
            if (onScanRequested != null) {
                OutlinedButton(onClick = onScanRequested) {
                    Text(stringResource(R.string.pairing_entry_scan))
                }
            }
        }
    }
}
