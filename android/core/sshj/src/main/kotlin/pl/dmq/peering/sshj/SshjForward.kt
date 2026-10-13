package pl.dmq.peering.sshj

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Parameters
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ssh.transport.SshForwardHandle
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/** OpenSSH's `-L`. The listener is bound to the loopback address only: 0.0.0.0 would expose the far end to the whole network. */
internal object SshjForward {
    private const val LOOPBACK = "127.0.0.1"

    fun open(client: SSHClient, localPort: Int, remoteHost: String, remotePort: Int): SshForwardHandle {
        val socket = ServerSocket()
        try {
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(InetAddress.getByName(LOOPBACK), localPort))
        } catch (failure: IOException) {
            socket.runCatching { close() }
            throw SshFailure.Forward("Port $localPort is already in use on this phone.")
        }
        val forwarder = client.newLocalPortForwarder(Parameters(LOOPBACK, localPort, remoteHost, remotePort), socket)
        thread(name = "ssh-forward-$localPort", isDaemon = true) { forwarder.runCatching { listen() } }
        return object : SshForwardHandle {
            override fun close() {
                forwarder.runCatching { close() }
                socket.runCatching { close() }
            }
        }
    }
}
