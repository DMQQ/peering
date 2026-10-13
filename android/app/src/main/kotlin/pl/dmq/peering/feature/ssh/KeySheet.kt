package pl.dmq.peering.feature.ssh

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshKeyPair
import pl.dmq.peering.sshj.SshKeyProblem
import pl.dmq.peering.sshj.SshKeys
import pl.dmq.peering.ui.kit.ControlPicker
import pl.dmq.peering.ui.kit.ControlToggle
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import java.io.InputStream

private enum class KeySource { GENERATE, PASTE }

private const val MAXIMUM_KEY_FILE_BYTES = 64 * 1024

/** Makes a key or takes one the user has: nothing is kept until Use this key. */
@Composable
internal fun KeySheet(onUse: (SshKeyPair) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var source by rememberSaveable { mutableStateOf(KeySource.GENERATE) }
    var label by rememberSaveable { mutableStateOf("") }
    var text by rememberSaveable { mutableStateOf("") }
    var hasPassphrase by rememberSaveable { mutableStateOf(false) }
    var passphrase by rememberSaveable { mutableStateOf("") }
    var problem by remember { mutableStateOf<SshKeyProblem?>(null) }
    var fileFailed by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val read = runCatching {
            context.contentResolver.openInputStream(uri)?.use { it.readUpTo(MAXIMUM_KEY_FILE_BYTES).decodeToString() }
        }.getOrNull()
        fileFailed = read == null
        if (read != null) {
            text = read
            source = KeySource.PASTE
            problem = null
        }
    }

    fun use() {
        working = true
        scope.launch {
            val result = withContext(Dispatchers.Default) {
                try {
                    val pair = if (source == KeySource.GENERATE) SshKeys.generate(label) else SshKeys.read(text, passphrase.takeIf { hasPassphrase })
                    Result.success(pair.labelled(label))
                } catch (failure: SshKeyProblem) {
                    Result.failure(failure)
                }
            }
            working = false
            result.onSuccess(onUse).onFailure { problem = it as SshKeyProblem }
        }
    }

    PeeringSheet(onDismiss, scrollable = true) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.ssh_key_title), style = PeeringText.display(size = 30f, tracking = -1f), color = PeeringColors.ink)
            ControlsCard(stringResource(R.string.ssh_key_where), footer = stringResource(sourceFooter(source))) {
                ControlPicker(
                    stringResource(R.string.ssh_key_where), Icons.Outlined.Key, source, KeySource.entries,
                    { stringResource(if (it == KeySource.GENERATE) R.string.ssh_key_generate else R.string.ssh_key_paste) },
                    { source = it; problem = null },
                )
                QuietButton({ picker.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.ssh_key_import_file)) }
            }
            if (source == KeySource.PASTE) PasteFields(text, { text = it; problem = null }, hasPassphrase, { hasPassphrase = it }, passphrase) { passphrase = it }
            ControlsCard(stringResource(R.string.ssh_key_name), footer = stringResource(R.string.ssh_key_name_footer)) {
                PeeringTextField(label, { label = it }, stringResource(R.string.ssh_key_name), Modifier.fillMaxWidth())
            }
            problem?.let { Text(keyProblemText(it), style = PeeringText.caption, color = PeeringColors.danger) }
            if (fileFailed) Text(stringResource(R.string.ssh_key_err_file), style = PeeringText.caption, color = PeeringColors.danger)
            PrimaryButton(
                stringResource(R.string.ssh_key_use), ::use,
                Modifier.height(44.dp), enabled = !working && (source == KeySource.GENERATE || text.isNotBlank()),
            )
        }
    }
}

@Composable
private fun PasteFields(
    text: String,
    onText: (String) -> Unit,
    hasPassphrase: Boolean,
    onHasPassphrase: (Boolean) -> Unit,
    passphrase: String,
    onPassphrase: (String) -> Unit,
) {
    ControlsCard(stringResource(R.string.ssh_key_text)) {
        PeeringTextField(text, onText, stringResource(R.string.ssh_key_text), Modifier.fillMaxWidth().height(160.dp), singleLine = false, monospaced = true)
    }
    ControlsCard(stringResource(R.string.ssh_key_passphrase), footer = stringResource(R.string.ssh_key_passphrase_footer)) {
        ControlToggle(stringResource(R.string.ssh_key_has_passphrase), Icons.Outlined.Lock, hasPassphrase, onHasPassphrase)
        if (hasPassphrase) {
            PeeringTextField(
                passphrase, onPassphrase, stringResource(R.string.ssh_key_passphrase), Modifier.fillMaxWidth(),
                visualTransformation = PasswordVisualTransformation(),
            )
        }
    }
}

private fun sourceFooter(source: KeySource) = when (source) {
    KeySource.GENERATE -> R.string.ssh_key_from_generate
    KeySource.PASTE -> R.string.ssh_key_from_paste
}

/** InputStream.readNBytes needs API 33, and the app supports 29. A key file is small; anything past the limit is cut off and fails to parse. */
private fun InputStream.readUpTo(limit: Int): ByteArray {
    val buffer = ByteArray(limit)
    var filled = 0
    while (filled < limit) {
        val count = read(buffer, filled, limit - filled)
        if (count < 0) break
        filled += count
    }
    return buffer.copyOf(filled)
}
