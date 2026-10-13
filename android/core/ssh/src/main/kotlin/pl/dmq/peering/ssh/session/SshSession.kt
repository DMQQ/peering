package pl.dmq.peering.ssh.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import pl.dmq.peering.ssh.bridge.SshWireBridge
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ssh.transport.SshConnectRequest
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ssh.transport.SshTransport
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import java.util.concurrent.CopyOnWriteArrayList

sealed interface SshPhase {
    data object Connecting : SshPhase

    data object Live : SshPhase

    /** [failure] is null when the user ended it. */
    data class Ended(val failure: SshFailure?) : SshPhase
}

/**
 * One server from tap to goodbye: connects (off the main thread, and abandoned at once if the user cancels while it
 * waits on the network or on a host key answer), opens a shell, brings up the saved tunnels, and reports how it ends.
 * Requests made before the link is up are kept and sent once it is, so a screen can attach the moment it appears.
 */
class SshSession(
    val host: SshHost,
    private val credential: SshCredential,
    private val transport: SshTransport,
    private val gate: HostKeyGate,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
) {
    private val mutablePhase = MutableStateFlow<SshPhase>(SshPhase.Connecting)
    private val listeners = CopyOnWriteArrayList<(TerminalEvent) -> Unit>()
    private val tunnels = SshForwards()
    private val lock = Any()
    private val waiting = ArrayList<TerminalRequest>()
    private var bridge: SshWireBridge? = null
    private var connection: SshConnection? = null
    private var attempt: Job? = null

    val phase: StateFlow<SshPhase> = mutablePhase.asStateFlow()

    val forwardStatus: StateFlow<Map<String, ForwardStatus>> = tunnels.status

    fun addListener(listener: (TerminalEvent) -> Unit) {
        listeners += listener
    }

    fun connect() {
        attempt = scope.launch { open() }
    }

    fun send(request: TerminalRequest) {
        val ready = synchronized(lock) { bridge ?: run { waiting += request; null } }
        ready?.send(request)
    }

    fun startForward(forward: SshPortForward) = tunnels.start(forward)

    fun stopForward(id: String) = tunnels.stop(id)

    /** The user is done. Ends the attempt if it is still going. */
    fun close() {
        attempt?.cancel()
        teardown()
        mutablePhase.compareAndSet(SshPhase.Connecting, SshPhase.Ended(null))
        mutablePhase.compareAndSet(SshPhase.Live, SshPhase.Ended(null))
    }

    private suspend fun open() {
        val link = try {
            dial()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: SshFailure) {
            return finish(failure)
        } catch (failure: Exception) {
            return finish(SshFailure.Transport(failure.message ?: "The connection failed."))
        }
        link.onLost { reason -> lost(reason) }
        val wire = SshWireBridge(link, scope, io) { event -> listeners.forEach { it(event) } }
        tunnels.attach(link)
        synchronized(lock) {
            bridge = wire
            connection = link
        }
        mutablePhase.value = SshPhase.Live
        wire.send(TerminalRequest.Create)
        val queued = synchronized(lock) { waiting.toList().also { waiting.clear() } }
        queued.forEach(wire::send)
        scope.launch(io) { host.forwards.filter { it.isEnabled }.forEach(tunnels::start) }
    }

    /**
     * Not a child of the scope: a failure here is an answer, not a crash. A cancelled attempt cannot interrupt a
     * blocking socket, so a connection that arrives late is closed on arrival.
     */
    private suspend fun dial(): SshConnection {
        val request = SshConnectRequest(host.endpoint, host.username, credential)
        val arrival = CompletableDeferred<SshConnection>()
        scope.launch(io) {
            try {
                arrival.complete(transport.connect(request, gate))
            } catch (failure: Exception) {
                arrival.completeExceptionally(failure)
            }
        }
        try {
            return arrival.await()
        } catch (cancelled: CancellationException) {
            arrival.invokeOnCompletion { problem ->
                if (problem == null) arrival.getCompleted().runCatching { close() }
            }
            throw cancelled
        }
    }

    private fun lost(reason: String?) {
        if (mutablePhase.value !is SshPhase.Live) return
        synchronized(lock) { bridge }?.connectionLost()
        teardown()
        mutablePhase.value = SshPhase.Ended(SshFailure.Transport(reason ?: "The connection ended."))
    }

    private fun finish(failure: SshFailure) {
        mutablePhase.value = SshPhase.Ended(failure)
    }

    private fun teardown() {
        val (wire, link) = synchronized(lock) {
            (bridge to connection).also {
                bridge = null
                connection = null
            }
        }
        tunnels.stopAll()
        wire?.close()
        link?.runCatching { close() }
    }
}
