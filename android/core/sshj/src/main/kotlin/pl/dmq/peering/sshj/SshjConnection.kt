package pl.dmq.peering.sshj

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.transport.DisconnectListener
import pl.dmq.peering.ssh.transport.SftpClient
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ssh.transport.SshForwardHandle
import pl.dmq.peering.ssh.transport.SshShell
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

internal class SshjConnection(private val client: SSHClient) : SshConnection {
    private val closing = AtomicBoolean(false)

    override val isOpen: Boolean get() = client.isConnected && client.isAuthenticated

    override fun onLost(listener: (reason: String?) -> Unit) {
        client.transport.disconnectListener = DisconnectListener { reason, message ->
            if (!closing.get()) listener(message?.takeIf { it.isNotBlank() } ?: reason?.toString())
        }
    }

    override fun openShell(columns: Int, rows: Int, onOutput: (ByteArray) -> Unit, onEnd: (Int?) -> Unit): SshShell =
        try {
            SshjShell.open(client, columns, rows, onOutput, onEnd)
        } catch (failure: IOException) {
            throw SshFailure.Transport(failure.message ?: "The shell could not be opened.")
        }

    override fun sftp(): SftpClient =
        try {
            SshjSftp(client.newSFTPClient())
        } catch (failure: IOException) {
            throw SshFailure.Browse("This server does not offer SFTP, so its files cannot be browsed.")
        }

    override fun forward(localPort: Int, remoteHost: String, remotePort: Int): SshForwardHandle =
        SshjForward.open(client, localPort, remoteHost, remotePort)

    override fun close() {
        closing.set(true)
        // The disconnect message is a socket write, which Android refuses on the main thread where a session is ended from.
        Thread({ client.runCatching { disconnect() } }, "ssh-closer").apply { isDaemon = true }.start()
    }
}
