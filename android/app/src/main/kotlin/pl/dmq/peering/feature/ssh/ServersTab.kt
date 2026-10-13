package pl.dmq.peering.feature.ssh

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.session.LiveServer

/** What the list screen has open over it. */
private sealed interface Overlay {
    data object Adding : Overlay

    data class Editing(val host: SshHost) : Overlay

    data class PublicKey(val host: SshHost) : Overlay

    data class ForgettingSignIn(val host: SshHost) : Overlay
}

/** The Servers tab: the list of servers, or the open server over it. Every question on the way to a shell is asked from here. */
@Composable
internal fun ServersTab(hub: SshHub) {
    val servers = hub.servers
    val hosts by servers.hosts.collectAsState()
    val live by servers.live.collectAsState()
    val selected by servers.selected.collectAsState()
    var overlay by remember { mutableStateOf<Overlay?>(null) }
    val open = live.firstOrNull { it.id == selected }

    if (open != null) {
        SshSessionScreen(
            server = open,
            hub = hub,
            method = servers.storedCredential(open.host).methodOrPassword(),
            onBack = { servers.select(null) },
            onEnd = { servers.close(open.id) },
            onReconnect = { reconnect(hub, open) },
        )
    } else {
        ServersScreen(
            hosts = hosts,
            live = live,
            facts = { host -> ServerFacts(servers.hasStoredCredential(host), servers.isKeyKnown(host), servers.storedCredential(host) is SshCredential.Key) },
            actions = ServerRowActions(
                open = servers::requestOpen,
                edit = { overlay = Overlay.Editing(it) },
                showPublicKey = { overlay = Overlay.PublicKey(it) },
                forgetSignIn = { overlay = Overlay.ForgettingSignIn(it) },
                forgetKey = servers::forgetKey,
                delete = servers::delete,
            ),
            onAdd = { overlay = Overlay.Adding },
            onOpenLive = { servers.select(it.id) },
            onEnd = { servers.close(it.id) },
        )
    }
    ServerOverlays(hub, overlay) { overlay = null }
    ServerQuestions(hub)
}

private fun reconnect(hub: SshHub, server: LiveServer) {
    val host = hub.servers.hosts.value.firstOrNull { it.id == server.id } ?: server.host
    hub.servers.close(server.id)
    hub.servers.requestOpen(host)
}

@Composable
private fun ServerOverlays(hub: SshHub, overlay: Overlay?, dismiss: () -> Unit) {
    val servers = hub.servers
    when (overlay) {
        null -> Unit
        Overlay.Adding -> HostEditorSheet(
            existing = null, storedKey = null, hasPasscode = false, newId = servers::newHostId,
            onSave = { result -> save(hub, result); dismiss() }, onDismiss = dismiss,
        )
        is Overlay.Editing -> HostEditorSheet(
            existing = overlay.host,
            storedKey = (servers.storedCredential(overlay.host) as? SshCredential.Key)?.pair,
            hasPasscode = servers.hasPasscode(overlay.host),
            newId = servers::newHostId,
            onSave = { result -> save(hub, result); dismiss() },
            onDismiss = dismiss,
        )
        is Overlay.PublicKey -> (servers.storedCredential(overlay.host) as? SshCredential.Key)?.let { PublicKeySheet(it.pair, dismiss) }
        is Overlay.ForgettingSignIn -> ForgetSignInDialog(
            overlay.host,
            onForget = { servers.forgetCredential(overlay.host); dismiss() },
            onKeep = dismiss,
        )
    }
}

private fun save(hub: SshHub, result: EditorResult) {
    hub.servers.save(result.host, result.passcode)
    if (result.forgetCredential) hub.servers.forgetCredential(result.host)
    hub.servers.apply(result.credential, result.host, remember = true)
}
