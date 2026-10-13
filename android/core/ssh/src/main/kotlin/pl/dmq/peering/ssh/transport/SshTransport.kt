package pl.dmq.peering.ssh.transport

import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshEndpoint

class SshConnectRequest(
    val endpoint: SshEndpoint,
    val username: String,
    val credential: SshCredential,
    val connectTimeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
) {
    companion object {
        const val DEFAULT_TIMEOUT_MILLIS = 15_000
    }
}

/**
 * The library behind one seam, so everything above it is tested with a fake. [connect] blocks, so callers run it off
 * the main thread, and it ends early when the thread is interrupted (a cancelled coroutine does that to a blocking call).
 */
interface SshTransport {
    /** Throws [SshFailure]. The [gate] is asked about the server's key during the handshake. */
    fun connect(request: SshConnectRequest, gate: HostKeyGate): SshConnection
}

interface SshConnection : AutoCloseable {
    val isOpen: Boolean

    /** Runs once when the server or the network ends the connection; [reason] is the library's sentence when it gave one. Not called for [close]. */
    fun onLost(listener: (reason: String?) -> Unit)

    /** [onOutput] gets stdout and stderr merged, as a terminal shows them; [onEnd] runs once with the exit status when known. */
    fun openShell(columns: Int, rows: Int, onOutput: (ByteArray) -> Unit, onEnd: (Int?) -> Unit): SshShell

    fun sftp(): SftpClient

    /** Listens on 127.0.0.1:[localPort] and tunnels each connection to [remoteHost]:[remotePort] through the server. */
    fun forward(localPort: Int, remoteHost: String, remotePort: Int): SshForwardHandle
}

interface SshShell : AutoCloseable {
    fun write(bytes: ByteArray)

    fun resize(columns: Int, rows: Int)
}

interface SshForwardHandle : AutoCloseable
