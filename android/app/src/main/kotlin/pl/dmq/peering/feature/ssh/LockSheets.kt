package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ui.kit.LinkButton
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Asked before a locked server opens. The device's own unlock is offered whichever lock is set, so a wrong passcode is never a dead end for biometrics. */
@Composable
internal fun UnlockSheet(
    host: SshHost,
    failures: Int,
    onPasscode: (String) -> Unit,
    onDevice: () -> Unit,
    onDismiss: () -> Unit,
) {
    PeeringSheet(onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(stringResource(R.string.ssh_unlock_title, host.displayName), style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
            if (host.lock == SshHostLock.PASSCODE) {
                PasscodePad(
                    prompt = stringResource(R.string.ssh_lock_enter),
                    resetKey = failures,
                    onComplete = onPasscode,
                    error = if (failures > 0) stringResource(R.string.ssh_lock_wrong) else null,
                )
            } else {
                Text(stringResource(R.string.ssh_lock_footer_device), style = PeeringText.subheadline, color = PeeringColors.muted)
            }
            LinkButton(stringResource(R.string.ssh_unlock_device), onDevice)
        }
    }
}

/** Two entries of the same six digits; the second must match the first. */
@Composable
internal fun PasscodeSetSheet(onSet: (String) -> Unit, onDismiss: () -> Unit) {
    var first by remember { mutableStateOf<String?>(null) }
    var mismatches by remember { mutableStateOf(0) }
    PeeringSheet(onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(stringResource(R.string.ssh_lock_choose), style = PeeringText.display(size = 28f, tracking = -0.8f), color = PeeringColors.ink)
            PasscodePad(
                prompt = stringResource(if (first == null) R.string.ssh_lock_choose else R.string.ssh_lock_again),
                resetKey = first to mismatches,
                onComplete = { digits ->
                    val earlier = first
                    when {
                        earlier == null -> first = digits
                        earlier == digits -> onSet(digits)
                        else -> {
                            first = null
                            mismatches++
                        }
                    }
                },
                error = if (mismatches > 0 && first == null) stringResource(R.string.ssh_lock_mismatch) else null,
            )
        }
    }
}
