package pl.dmq.peering.feature.ssh

import android.content.ContentResolver
import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import pl.dmq.peering.AppGraph
import pl.dmq.peering.SecureRandomSource
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.feature.terminal.AgentLaunchHistory
import pl.dmq.peering.feature.terminal.QuickCommands
import pl.dmq.peering.feature.terminal.TerminalPreferences
import pl.dmq.peering.feature.terminal.TerminalTextSizeSetting
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.session.LiveServer
import pl.dmq.peering.ssh.session.SshServers
import pl.dmq.peering.ssh.store.PrefixedKeyValueStore
import pl.dmq.peering.ssh.store.SshCredentialStore
import pl.dmq.peering.ssh.store.SshHostStore
import pl.dmq.peering.ssh.store.SshPasscodeStore
import pl.dmq.peering.sshj.SshjTransport
import pl.dmq.peering.ui.wiring.PreferencesKeyValueStore
import java.util.UUID

/** Everything the Servers tab shares for the life of the process: the servers, their saved secrets and the shells' settings. */
internal class SshHub(graph: AppGraph, private val scope: CoroutineScope, preferences: SharedPreferences) {
    private val secrets: SecretStore = graph.sealedSecrets

    val servers = SshServers(
        hostStore = SshHostStore(secrets),
        credentials = SshCredentialStore(secrets),
        passcodes = SshPasscodeStore(secrets, SecureRandomSource()),
        knownHosts = KnownHostsStore(secrets),
        transport = SshjTransport(),
        scope = scope,
        io = Dispatchers.IO,
        nowMillis = System::currentTimeMillis,
        newId = { UUID.randomUUID().toString() },
    )

    val terminalPreferences: TerminalPreferences = PrefixedKeyValueStore(
        PreferencesKeyValueStore(preferences, graph.preferenceWrites),
        KEY_PREFIX,
    ).let { TerminalPreferences(QuickCommands(it), TerminalTextSizeSetting(it), AgentLaunchHistory(it)) }

    private val files = HashMap<String, SshFiles>()

    init {
        scope.launch {
            servers.live.collect { live ->
                synchronized(files) {
                    val gone = files.keys - live.map { it.id }.toSet()
                    gone.forEach { files.remove(it)?.close() }
                }
            }
        }
    }

    /** One file browser per open server, kept for as long as the server is open so a download survives leaving the tab. */
    fun files(server: LiveServer, resolver: ContentResolver): FileBrowsingPort =
        synchronized(files) { files.getOrPut(server.id) { SshFiles(server, resolver, scope) } }.port

    private companion object {
        const val KEY_PREFIX = "ssh_"
    }
}
