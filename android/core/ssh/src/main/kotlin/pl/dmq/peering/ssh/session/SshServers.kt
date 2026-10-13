package pl.dmq.peering.ssh.session

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.hostkey.HostKeyPrompter
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.store.SshCredentialStore
import pl.dmq.peering.ssh.store.SshHostStore
import pl.dmq.peering.ssh.store.SshPasscodeStore
import pl.dmq.peering.ssh.transport.SshTransport

/** A connection with its shells' screens. [id] is the server's, so tapping a server that is already open finds it. */
class LiveServer(val session: SshSession, val terminals: TerminalSessions) {
    val host: SshHost get() = session.host
    val id: String get() = host.id
}

/** What stands between a tap and the shell. Only one is asked at a time. */
sealed interface OpenGate {
    /** [rejected] is true after a wrong passcode, so the sheet can say so. */
    data class Locked(val host: SshHost, val rejected: Boolean = false) : OpenGate

    data class NeedsPassword(val host: SshHost) : OpenGate
}

/**
 * The Servers tab's brain: the saved servers, the open connections, and the order of questions before one opens
 * (the lock, then a password if none is saved). A lock is checked here, on the one way in, because a check on a row's
 * tap is walked past by every other entrance.
 */
class SshServers(
    private val hostStore: SshHostStore,
    private val credentials: SshCredentialStore,
    private val passcodes: SshPasscodeStore,
    private val knownHosts: KnownHostsStore,
    private val transport: SshTransport,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val nowMillis: () -> Long,
    private val newId: () -> String,
) {
    val prompter = HostKeyPrompter()

    private val mutableHosts = MutableStateFlow(SshHostStore.ordered(hostStore.load()))
    private val mutableLive = MutableStateFlow<List<LiveServer>>(emptyList())
    private val mutableSelected = MutableStateFlow<String?>(null)
    private val mutableGate = MutableStateFlow<OpenGate?>(null)

    val hosts: StateFlow<List<SshHost>> = mutableHosts.asStateFlow()
    val live: StateFlow<List<LiveServer>> = mutableLive.asStateFlow()

    /** The id of the open server on screen, or null for the list. */
    val selected: StateFlow<String?> = mutableSelected.asStateFlow()
    val gate: StateFlow<OpenGate?> = mutableGate.asStateFlow()

    fun newHostId(): String = newId()

    /** Saves [host], and its passcode when it is locked by one. A passcode that could not be stored leaves the server unlocked, visibly, rather than locked with no way in. */
    fun save(host: SshHost, passcode: String? = null) {
        var accepted = host
        if (host.lock == SshHostLock.PASSCODE) {
            val stored = if (passcode != null) passcodes.set(passcode, host.id) else passcodes.hasPasscode(host.id)
            if (!stored) accepted = host.copy(lock = SshHostLock.OFF)
        } else {
            passcodes.remove(host.id)
        }
        persist { list -> if (list.any { it.id == accepted.id }) list.map { if (it.id == accepted.id) accepted else it } else list + accepted }
    }

    /** Whether the credential was kept. A null [credential] leaves what is saved as it is. */
    fun apply(credential: SshCredential?, host: SshHost, remember: Boolean): Boolean {
        if (credential == null) return true
        return if (remember || credential is SshCredential.Key) credentials.save(credential, host.id) else credentials.remove(host.id)
    }

    fun delete(host: SshHost) {
        close(host.id)
        credentials.remove(host.id)
        passcodes.remove(host.id)
        knownHosts.forget(host.endpoint)
        persist { list -> list.filterNot { it.id == host.id } }
    }

    fun storedCredential(host: SshHost): SshCredential? = credentials.credential(host.id)

    fun hasStoredCredential(host: SshHost): Boolean = credentials.hasCredential(host.id)

    fun hasPasscode(host: SshHost): Boolean = passcodes.hasPasscode(host.id)

    fun forgetCredential(host: SshHost) {
        credentials.remove(host.id)
    }

    fun isKeyKnown(host: SshHost): Boolean = knownHosts.host(host.endpoint) != null

    /** The only route past a changed key, so it is a deliberate act on the server's own row. */
    fun forgetKey(host: SshHost) {
        knownHosts.forget(host.endpoint)
    }

    fun requestOpen(host: SshHost) {
        if (mutableLive.value.any { it.id == host.id }) return select(host.id)
        if (host.lock.isLocked) mutableGate.value = OpenGate.Locked(host) else proceed(host)
    }

    /** Called once the device's own unlock (biometrics or its fallback) has been satisfied. */
    fun unlockedByDevice(host: SshHost) = accept(host)

    fun submitPasscode(code: String, host: SshHost) {
        if (!SshPasscodeStore.isValid(code)) return
        if (passcodes.verify(code, host.id)) accept(host) else mutableGate.value = OpenGate.Locked(host, rejected = true)
    }

    fun submitPassword(password: String, remember: Boolean, host: SshHost) {
        mutableGate.value = null
        val credential = SshCredential.Password(password)
        if (remember) credentials.save(credential, host.id)
        connect(host, credential)
    }

    fun cancelGate() {
        mutableGate.value = null
    }

    fun select(id: String?) {
        mutableSelected.value = id
    }

    /** Ends the connection, answers its pending host-key questions with no, and removes it. */
    fun close(id: String) {
        val server = mutableLive.value.firstOrNull { it.id == id } ?: return
        prompter.refuse(id)
        server.session.close()
        mutableLive.update { list -> list.filterNot { it.id == id } }
        if (mutableSelected.value == id) mutableSelected.value = null
    }

    fun closeAll() {
        prompter.refuseAll()
        mutableLive.value.forEach { it.session.close() }
        mutableLive.value = emptyList()
        mutableSelected.value = null
    }

    private fun accept(host: SshHost) {
        mutableGate.value = null
        proceed(host)
    }

    private fun proceed(host: SshHost) {
        val credential = credentials.credential(host.id)
        if (credential == null) mutableGate.value = OpenGate.NeedsPassword(host) else connect(host, credential)
    }

    private fun connect(host: SshHost, credential: SshCredential) {
        val gate = HostKeyGate(knownHosts, nowMillis) { prompt -> prompter.ask(prompt, host.id) }
        val session = SshSession(host, credential, transport, gate, scope, io)
        val terminals = TerminalSessions(send = session::send, scope = scope)
        session.addListener(terminals::onEvent)
        val server = LiveServer(session, terminals)
        mutableLive.update { it + server }
        mutableSelected.value = host.id
        session.connect()
        scope.launch {
            if (session.phase.first { it !is SshPhase.Connecting } is SshPhase.Live) markConnected(host.id)
        }
    }

    private fun markConnected(id: String) {
        persist { list -> list.map { if (it.id == id) it.copy(lastConnectedAt = nowMillis()) else it } }
    }

    private fun persist(change: (List<SshHost>) -> List<SshHost>) {
        mutableHosts.update { SshHostStore.ordered(change(it)) }
        hostStore.save(mutableHosts.value)
    }
}
