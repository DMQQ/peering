package pl.dmq.peering.sshj

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import pl.dmq.peering.ssh.transport.SshShell
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

internal class SshjShell private constructor(
    private val session: Session,
    private val shell: Session.Shell,
) : SshShell {
    override fun write(bytes: ByteArray) {
        shell.outputStream.write(bytes)
        shell.outputStream.flush()
    }

    override fun resize(columns: Int, rows: Int) {
        shell.changeWindowDimensions(columns, rows, 0, 0)
    }

    override fun close() {
        shell.runCatching { close() }
        session.runCatching { close() }
    }

    companion object {
        private const val TERM = "xterm-256color"
        private const val READ_BUFFER = 8 * 1024
        private const val EXIT_STATUS_WAIT_SECONDS = 1L

        fun open(client: SSHClient, columns: Int, rows: Int, onOutput: (ByteArray) -> Unit, onEnd: (Int?) -> Unit): SshjShell {
            val session = client.startSession()
            session.allocatePTY(TERM, columns, rows, 0, 0, emptyMap())
            val shell = session.startShell()
            thread(name = "ssh-shell-reader", isDaemon = true) {
                val buffer = ByteArray(READ_BUFFER)
                try {
                    while (true) {
                        val count = shell.inputStream.read(buffer)
                        if (count < 0) break
                        onOutput(buffer.copyOf(count))
                    }
                } catch (_: IOException) {
                    // The channel closed under the read: the shell ended or the link did.
                }
                // The exit status can trail the end of the stream by a packet.
                shell.runCatching { join(EXIT_STATUS_WAIT_SECONDS, TimeUnit.SECONDS) }
                // The session and the shell are one channel object; only its Command face carries the status.
                onEnd((session as? Session.Command)?.exitStatus)
            }
            return SshjShell(session, shell)
        }
    }
}
