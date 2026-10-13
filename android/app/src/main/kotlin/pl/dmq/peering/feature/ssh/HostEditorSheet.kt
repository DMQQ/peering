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
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.PersonOutline
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
import pl.dmq.peering.ssh.model.SshAuthMethod
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostForm
import pl.dmq.peering.ssh.model.SshHostFormReading
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.model.SshKeyPair
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What saving the editor asks for beyond the server itself. A null [credential] leaves what is saved as it is. */
internal class EditorResult(val host: SshHost, val credential: SshCredential?, val forgetCredential: Boolean, val passcode: String?)

@Composable
internal fun HostEditorSheet(
    existing: SshHost?,
    storedKey: SshKeyPair?,
    hasPasscode: Boolean,
    newId: () -> String,
    onSave: (EditorResult) -> Unit,
    onDismiss: () -> Unit,
) {
    var form by remember { mutableStateOf(existing?.let(SshHostForm::of) ?: SshHostForm()) }
    var method by remember { mutableStateOf(if (storedKey != null) SshAuthMethod.KEY else SshAuthMethod.PASSWORD) }
    var key by remember { mutableStateOf(storedKey) }
    var passcode by remember { mutableStateOf<String?>(null) }
    var choosingKey by remember { mutableStateOf(false) }
    var choosingPasscode by remember { mutableStateOf(false) }
    var attempted by remember { mutableStateOf(false) }

    val reading = form.reading(existing, newId) { System.currentTimeMillis() }
    val needsPasscode = form.lock == SshHostLock.PASSCODE && passcode == null && !hasPasscode
    val needsKey = method == SshAuthMethod.KEY && key == null

    fun save() {
        attempted = true
        val valid = reading as? SshHostFormReading.Valid ?: return
        if (needsPasscode || needsKey) return
        val credential = key?.takeIf { method == SshAuthMethod.KEY && it != storedKey }?.let { SshCredential.Key(it) }
        onSave(EditorResult(valid.host, credential, forgetCredential = method == SshAuthMethod.PASSWORD && storedKey != null, passcode = passcode))
    }

    PeeringSheet(onDismiss, scrollable = true) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                stringResource(if (existing == null) R.string.ssh_editor_add_title else R.string.ssh_editor_edit_title),
                style = PeeringText.display(size = 30f, tracking = -1f), color = PeeringColors.ink,
            )
            ServerFields(form, { form = it }, reading, attempted)
            LockCard(form.lock, { form = form.copy(lock = it) }, passcode != null || hasPasscode, { choosingPasscode = true })
            SignInCard(method, { method = it }, key, { choosingKey = true })
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LinkButton(stringResource(R.string.ssh_cancel), onDismiss, Modifier.width(96.dp))
                PrimaryButton(stringResource(R.string.ssh_save), ::save, Modifier.height(44.dp), enabled = !attempted || (reading is SshHostFormReading.Valid && !needsPasscode && !needsKey))
            }
        }
    }
    if (choosingKey) KeySheet(onUse = { key = it; choosingKey = false }, onDismiss = { choosingKey = false })
    if (choosingPasscode) PasscodeSetSheet(onSet = { passcode = it; choosingPasscode = false }, onDismiss = { choosingPasscode = false })
}

@Composable
private fun ServerFields(form: SshHostForm, onForm: (SshHostForm) -> Unit, reading: SshHostFormReading, attempted: Boolean) {
    ControlsCard(stringResource(R.string.ssh_server_card), footer = stringResource(R.string.ssh_server_footer)) {
        PeeringTextField(form.name, { onForm(form.copy(name = it)) }, stringResource(R.string.ssh_field_name), Modifier.fillMaxWidth())
        PeeringTextField(
            form.hostname, { onForm(form.copy(hostname = it)) }, stringResource(R.string.ssh_field_host), Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PeeringTextField(
                form.port, { onForm(form.copy(port = it.filter(Char::isDigit))) }, stringResource(R.string.ssh_field_port), Modifier.width(96.dp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
            )
            PeeringTextField(
                form.username, { onForm(form.copy(username = it)) }, stringResource(R.string.ssh_field_user), Modifier.weight(1f),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Done),
            )
        }
        if (attempted && reading is SshHostFormReading.Invalid) {
            reading.errors.forEach { Text(hostErrorText(it), style = PeeringText.caption, color = PeeringColors.danger) }
        }
    }
}

@Composable
private fun LockCard(lock: SshHostLock, onLock: (SshHostLock) -> Unit, passcodeSet: Boolean, onChoosePasscode: () -> Unit) {
    val footer = when (lock) {
        SshHostLock.OFF -> R.string.ssh_lock_footer_off
        SshHostLock.PASSCODE -> R.string.ssh_lock_footer_passcode
        SshHostLock.BIOMETRICS -> R.string.ssh_lock_footer_device
    }
    ControlsCard(stringResource(R.string.ssh_lock_card), footer = stringResource(footer)) {
        ControlPicker(
            stringResource(R.string.ssh_lock_ask), Icons.Outlined.Lock, lock, SshHostLock.entries,
            {
                stringResource(
                    when (it) {
                        SshHostLock.OFF -> R.string.ssh_lock_nothing
                        SshHostLock.PASSCODE -> R.string.ssh_lock_passcode
                        SshHostLock.BIOMETRICS -> R.string.ssh_lock_device
                    },
                )
            },
            onLock,
        )
        if (lock == SshHostLock.PASSCODE) {
            ControlLink(stringResource(if (passcodeSet) R.string.ssh_lock_change else R.string.ssh_lock_choose), Icons.Outlined.PersonOutline, onChoosePasscode)
        }
    }
}

@Composable
private fun SignInCard(method: SshAuthMethod, onMethod: (SshAuthMethod) -> Unit, key: SshKeyPair?, onChooseKey: () -> Unit) {
    val footer = if (method == SshAuthMethod.KEY) R.string.ssh_signin_key_footer else R.string.ssh_signin_password_footer
    ControlsCard(stringResource(R.string.ssh_signin_card), footer = stringResource(footer)) {
        ControlPicker(
            stringResource(R.string.ssh_signin_using), Icons.Outlined.Key, method, SshAuthMethod.entries,
            { stringResource(if (it == SshAuthMethod.KEY) R.string.ssh_signin_key else R.string.ssh_signin_password) },
            onMethod,
        )
        if (method == SshAuthMethod.KEY) {
            ControlLink(
                stringResource(if (key == null) R.string.ssh_signin_key_missing else R.string.ssh_key_title),
                Icons.Outlined.Key, onChooseKey, detail = key?.let { it.algorithm.removePrefix("ssh-") },
            )
        }
    }
}
