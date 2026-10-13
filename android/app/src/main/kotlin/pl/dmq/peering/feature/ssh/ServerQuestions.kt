package pl.dmq.peering.feature.ssh

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.fragment.app.FragmentActivity
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.session.OpenGate
import pl.dmq.peering.ssh.session.SshServers
import pl.dmq.peering.ui.wiring.DeviceUnlock
import pl.dmq.peering.ui.wiring.findActivity

/** The questions between a tap and a shell, in the order they come: the lock, a password, then the server's key. */
@Composable
internal fun ServerQuestions(hub: SshHub) {
    val servers = hub.servers
    val gate by servers.gate.collectAsState()
    val prompt by servers.prompter.current.collectAsState()
    when (val asking = gate) {
        null -> Unit
        is OpenGate.Locked -> {
            val unlockWithDevice = rememberDeviceUnlock(servers, asking.host)
            LaunchedEffect(asking.host.id) { if (asking.host.lock == SshHostLock.BIOMETRICS) unlockWithDevice() }
            UnlockSheet(asking.host, asking.failures, { servers.submitPasscode(it, asking.host) }, unlockWithDevice, servers::cancelGate)
        }
        is OpenGate.NeedsPassword -> PasswordPromptSheet(
            asking.host,
            onConnect = { password, remember -> servers.submitPassword(password, remember, asking.host) },
            onDismiss = servers::cancelGate,
        )
    }
    prompt?.let { HostKeyPromptSheet(it, servers.prompter::answer) }
}

@Composable
private fun rememberDeviceUnlock(servers: SshServers, host: SshHost): () -> Unit {
    val context = LocalContext.current
    val title = stringResource(R.string.ssh_unlock_reason, host.displayName)
    return {
        val activity = context.findActivity() as? FragmentActivity
        if (activity == null || !DeviceUnlock.isAvailable(context)) {
            // A phone with no screen lock has nothing to ask, and refusing would lock the owner out of their own server.
            // A passcode lock is not given this way round: its pad is still there.
            if (host.lock == SshHostLock.BIOMETRICS) servers.unlockedByDevice(host)
        } else {
            DeviceUnlock.prompt(activity, title) { unlocked -> if (unlocked) servers.unlockedByDevice(host) }
        }
    }
}
