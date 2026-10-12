package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun Composer(presenter: ComposerPresenter, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    Column(modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (ui.attachedPaths.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ui.attachedPaths.forEachIndexed { index, path ->
                    OutlinedButton(onClick = { presenter.detach(index) }) {
                        Text(path.substringAfterLast('/'), style = MaterialTheme.typography.labelMedium, maxLines = 1)
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = ui.text,
                onValueChange = presenter::onTextChanged,
                modifier = Modifier.weight(1f),
                enabled = ui.sessionID != null,
                placeholder = {
                    Text(
                        stringResource(
                            if (ui.action == ComposerAction.SEND) R.string.composer_placeholder else R.string.composer_placeholder_queue,
                        ),
                    )
                },
                maxLines = 6,
            )
            SendButton(ui.action, ui.actionEnabled, presenter::send, presenter::stop)
        }
        if (ui.sessionID != null && (ui.permissionModes.isNotEmpty() || ui.modelChoices.isNotEmpty())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (ui.permissionModes.isNotEmpty()) {
                    PermissionModeMenu(ui.permissionMode, ui.permissionModes, ui.agentID, presenter::setPermissionMode)
                }
                if (ui.modelChoices.isNotEmpty()) {
                    ModelMenu(ui.model, ui.modelChoices, presenter::setModel)
                }
            }
        }
    }
}

@Composable
private fun SendButton(action: ComposerAction, enabled: Boolean, onSend: () -> Unit, onStop: () -> Unit) {
    if (action == ComposerAction.STOP) {
        OutlinedButton(onClick = onStop, enabled = enabled) {
            Text(stringResource(R.string.composer_stop), style = MaterialTheme.typography.labelLarge)
        }
    } else {
        Button(
            onClick = onSend,
            enabled = enabled,
            colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
        ) {
            Text(
                stringResource(if (action == ComposerAction.QUEUE) R.string.composer_queue else R.string.composer_send),
                style = MaterialTheme.typography.labelLarge,
            )
        }
    }
}
