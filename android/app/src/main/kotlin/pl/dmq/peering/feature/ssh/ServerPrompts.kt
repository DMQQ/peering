package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.hostkey.HostKeyPrompt
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshKeyPair
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The first time a server is reached: its fingerprint, to check against the server itself, and a Trust that is never the default. */
@Composable
internal fun HostKeyPromptSheet(prompt: HostKeyPrompt, onAnswer: (Boolean) -> Unit) {
    PeeringSheet({ onAnswer(false) }) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.ssh_hostkey_title), style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
            Text(stringResource(R.string.ssh_hostkey_body, prompt.endpoint.display), style = PeeringText.subheadline, color = PeeringColors.muted)
            ControlsCard(prompt.algorithm) {
                Text(prompt.fingerprint, style = PeeringText.subheadline.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.ink)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                QuietButton({ onAnswer(false) }, Modifier.weight(1f).height(44.dp)) { Text(stringResource(R.string.ssh_cancel)) }
                PrimaryButton(stringResource(R.string.ssh_hostkey_trust), { onAnswer(true) }, Modifier.weight(1f).height(44.dp))
            }
        }
    }
}

@Composable
internal fun PasswordPromptSheet(host: SshHost, onConnect: (password: String, remember: Boolean) -> Unit, onDismiss: () -> Unit) {
    var password by remember { mutableStateOf("") }
    var remembered by remember { mutableStateOf(false) }
    PeeringSheet(onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.ssh_password_title, host.detail), style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
            PeeringTextField(
                password, { password = it }, stringResource(R.string.ssh_password_field), Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { if (password.isNotEmpty()) onConnect(password, remembered) }),
                visualTransformation = PasswordVisualTransformation(),
            )
            ControlToggle(stringResource(R.string.ssh_password_remember), Icons.Outlined.Lock, remembered, { remembered = it })
            PrimaryButton(stringResource(R.string.ssh_password_connect), { onConnect(password, remembered) }, Modifier.height(44.dp), enabled = password.isNotEmpty())
        }
    }
}

/** The line the user puts in the server's authorized_keys, for copying. */
@Composable
internal fun PublicKeySheet(key: SshKeyPair, onDismiss: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    PeeringSheet(onDismiss, scrollable = true) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.ssh_key_public), style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
            ControlsCard(key.algorithm, footer = stringResource(R.string.ssh_key_public_footer)) {
                Text(key.publicKey, style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.ink)
            }
            PrimaryButton(
                stringResource(if (copied) R.string.ssh_key_copied else R.string.ssh_key_copy),
                {
                    clipboard.setText(AnnotatedString(key.publicKey))
                    copied = true
                },
                Modifier.height(44.dp),
            )
        }
    }
}

@Composable
internal fun ForgetSignInDialog(host: SshHost?, onForget: () -> Unit, onKeep: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.ssh_forget_title),
        message = stringResource(R.string.ssh_forget_body, host?.displayName ?: stringResource(R.string.ssh_this_server)),
        confirm = stringResource(R.string.ssh_forget_confirm),
        onConfirm = onForget,
        cancel = stringResource(R.string.ssh_forget_keep),
        onCancel = onKeep,
        destructive = true,
    )
}

@Composable
internal fun EndConnectionDialog(onEnd: () -> Unit, onKeep: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.ssh_end_title),
        message = stringResource(R.string.ssh_end_body),
        confirm = stringResource(R.string.ssh_end_confirm),
        onConfirm = onEnd,
        cancel = stringResource(R.string.ssh_forget_keep),
        onCancel = onKeep,
        destructive = true,
    )
}
