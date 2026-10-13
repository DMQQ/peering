package pl.dmq.peering.ssh.session

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshForwardHandle

sealed interface ForwardStatus {
    data object Stopped : ForwardStatus

    data object Running : ForwardStatus

    /** [reason] names what went wrong for this tunnel alone: a refused channel says nothing about the shell, which stays usable. */
    data class Failed(val reason: String) : ForwardStatus
}

/** The tunnels of one session and whether each is up. Intent (which are enabled) lives on the saved server. */
class SshForwards {
    private val handles = HashMap<String, SshForwardHandle>()
    private val mutableStatus = MutableStateFlow<Map<String, ForwardStatus>>(emptyMap())
    private var connection: SshConnection? = null

    val status: StateFlow<Map<String, ForwardStatus>> = mutableStatus.asStateFlow()

    @Synchronized
    fun attach(link: SshConnection) {
        connection = link
    }

    @Synchronized
    fun start(forward: SshPortForward) {
        val link = connection ?: return
        if (forward.id in handles) return
        try {
            handles[forward.id] = link.forward(forward.localPort, forward.remoteHost, forward.remotePort)
            mutableStatus.update { it + (forward.id to ForwardStatus.Running) }
        } catch (failure: Exception) {
            val reason = failure.message ?: "The tunnel could not be opened."
            mutableStatus.update { it + (forward.id to ForwardStatus.Failed(reason)) }
        }
    }

    @Synchronized
    fun stop(id: String) {
        handles.remove(id)?.runCatching { close() }
        mutableStatus.update { it + (id to ForwardStatus.Stopped) }
    }

    @Synchronized
    fun stopAll() {
        handles.values.forEach { it.runCatching { close() } }
        handles.clear()
        connection = null
        mutableStatus.update { current -> current.mapValues { ForwardStatus.Stopped } }
    }
}
