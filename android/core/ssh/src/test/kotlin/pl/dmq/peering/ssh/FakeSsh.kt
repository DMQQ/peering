package pl.dmq.peering.ssh

import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.transport.SftpClient
import pl.dmq.peering.ssh.transport.SftpListing
import pl.dmq.peering.ssh.transport.SftpPiece
import pl.dmq.peering.ssh.transport.SftpUpload
import pl.dmq.peering.ssh.transport.SshConnectRequest
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ssh.transport.SshForwardHandle
import pl.dmq.peering.ssh.transport.SshShell
import pl.dmq.peering.ssh.transport.SshTransport
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FakeShell(val onOutput: (ByteArray) -> Unit, val onEnd: (Int?) -> Unit) : SshShell {
    val written = StringBuilder()
    var size = 0 to 0
    var closed = false

    override fun write(bytes: ByteArray) {
        written.append(bytes.decodeToString())
    }

    override fun resize(columns: Int, rows: Int) {
        size = columns to rows
    }

    override fun close() {
        closed = true
    }
}

class FakeSftp : SftpClient {
    val files = mutableMapOf<String, ByteArray>()
    val calls = mutableListOf<String>()
    var uploaded = ByteArray(0)

    var entries = emptyList<RemoteDirectoryEntry>()

    override fun list(path: String?) = SftpListing(path ?: "/home/me", entries)

    override fun read(path: String, offset: Long, length: Int): SftpPiece {
        val bytes = files[path] ?: throw SshFailure.Browse("No such file")
        val end = minOf(bytes.size.toLong(), offset + length).toInt()
        return SftpPiece(bytes.copyOfRange(minOf(offset.toInt(), end), end), bytes.size.toLong())
    }

    override fun beginWrite(path: String): SftpUpload {
        uploaded = ByteArray(0)
        return object : SftpUpload {
            override fun write(bytes: ByteArray) {
                uploaded += bytes
            }

            override fun finish() = uploaded.size.toLong()

            override fun close() = Unit
        }
    }

    override fun createFile(path: String) {
        calls += "file $path"
    }

    override fun createFolder(path: String) {
        calls += "folder $path"
    }

    override fun rename(path: String, newName: String) {
        calls += "rename $path $newName"
    }

    override fun delete(path: String): String {
        calls += "delete $path"
        return "Deleted"
    }

    override fun close() = Unit
}

class FakeConnection : SshConnection {
    val shells = mutableListOf<FakeShell>()
    val sftp = FakeSftp()
    val forwarded = mutableListOf<Triple<Int, String, Int>>()
    var forwardFailure: String? = null
    var closed = false
    private var lostListener: ((String?) -> Unit)? = null

    override val isOpen get() = !closed

    override fun onLost(listener: (String?) -> Unit) {
        lostListener = listener
    }

    fun lose(reason: String?) = lostListener?.invoke(reason)

    override fun openShell(columns: Int, rows: Int, onOutput: (ByteArray) -> Unit, onEnd: (Int?) -> Unit): SshShell =
        FakeShell(onOutput, onEnd).also { shells += it }

    override fun sftp() = sftp

    override fun forward(localPort: Int, remoteHost: String, remotePort: Int): SshForwardHandle {
        forwardFailure?.let { throw SshFailure.Forward(it) }
        forwarded += Triple(localPort, remoteHost, remotePort)
        return object : SshForwardHandle {
            override fun close() = Unit
        }
    }

    override fun close() {
        closed = true
    }
}

class FakeTransport(private val connection: FakeConnection = FakeConnection()) : SshTransport {
    val connectionClosed: Boolean get() = connection.closed
    var failure: SshFailure? = null
    var seen: SshConnectRequest? = null

    override fun connect(request: SshConnectRequest, gate: HostKeyGate): SshConnection {
        seen = request
        failure?.let { throw it }
        return connection
    }
}
