package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshForwardReading
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Three fields and a switch, read per keystroke so the sentence naming the field at fault is always current. */
@Composable
internal fun ForwardEditorSheet(
    existing: List<SshPortForward>,
    editing: SshPortForward?,
    newId: () -> String,
    onSave: (SshPortForward) -> Unit,
    onDelete: (SshPortForward) -> Unit,
    onDismiss: () -> Unit,
) {
    var label by remember { mutableStateOf(editing?.label.orEmpty()) }
    var local by remember { mutableStateOf(editing?.localPort?.toString().orEmpty()) }
    var host by remember { mutableStateOf(editing?.remoteHost.orEmpty()) }
    var remote by remember { mutableStateOf(editing?.remotePort?.toString().orEmpty()) }
    var enabled by remember { mutableStateOf(editing?.isEnabled ?: true) }
    var touched by remember { mutableStateOf(false) }
    val reading = SshPortForward.reading(label, local, host, remote, existing, editing?.id, newId)

    PeeringSheet(onDismiss, scrollable = true) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.ssh_forward_title), style = PeeringText.display(size = 30f, tracking = -1f), color = PeeringColors.ink)
            ControlsCard(stringResource(R.string.ssh_forward_title)) {
                PeeringTextField(label, { label = it }, stringResource(R.string.ssh_forward_name), Modifier.fillMaxWidth())
            }
            ControlsCard(
                stringResource(R.string.ssh_forward_local_card),
                footer = stringResource(R.string.ssh_forward_local_footer, local.ifEmpty { "8080" }),
            ) {
                PeeringTextField(local, { local = it.filter(Char::isDigit); touched = true }, stringResource(R.string.ssh_forward_local), Modifier.fillMaxWidth(), keyboardOptions = numeric())
            }
            ControlsCard(stringResource(R.string.ssh_forward_remote_card), footer = stringResource(R.string.ssh_forward_remote_footer)) {
                PeeringTextField(host, { host = it; touched = true }, stringResource(R.string.ssh_forward_remote_host), Modifier.fillMaxWidth())
                PeeringTextField(remote, { remote = it.filter(Char::isDigit); touched = true }, stringResource(R.string.ssh_forward_remote_port), Modifier.width(120.dp), keyboardOptions = numeric())
            }
            ControlsCard(stringResource(R.string.ssh_forward_when_card), footer = stringResource(R.string.ssh_forward_when_footer)) {
                ControlToggle(stringResource(R.string.ssh_forward_enabled), Icons.Outlined.PlayArrow, enabled, { enabled = it })
            }
            if (touched && reading is SshForwardReading.Invalid) {
                Text(forwardErrorText(reading.error, reading.port), style = PeeringText.caption, color = PeeringColors.danger)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (editing != null) LinkButton(stringResource(R.string.ssh_forward_delete), { onDelete(editing) })
                PrimaryButton(
                    stringResource(R.string.ssh_save),
                    { (reading as? SshForwardReading.Valid)?.let { onSave(it.forward.copy(isEnabled = enabled)) } },
                    Modifier.height(44.dp), enabled = reading is SshForwardReading.Valid,
                )
            }
        }
    }
}

private fun numeric() = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next)
