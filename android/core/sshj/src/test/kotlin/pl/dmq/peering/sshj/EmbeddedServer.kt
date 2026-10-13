package pl.dmq.peering.sshj

import org.apache.sshd.common.config.keys.AuthorizedKeyEntry
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntryResolver
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.forward.AcceptAllForwardingFilter
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.server.shell.InteractiveProcessShellFactory
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.nio.file.Path

/** A real SSH server on a loopback port, so the glue is tested against the protocol and not against a mock of the library. */
class EmbeddedServer(
    root: Path,
    private val password: String? = "pw",
    private val authorizedKeyLine: String? = null,
    algorithm: String = "EC",
) : AutoCloseable {
    private val server: SshServer = SshServer.setUpDefaultServer().apply {
        host = "127.0.0.1"
        port = 0
        keyPairProvider = SimpleGeneratorHostKeyProvider().apply { setAlgorithm(algorithm) }
        passwordAuthenticator = org.apache.sshd.server.auth.password.PasswordAuthenticator { user, given, _ ->
            password != null && user == "me" && given == password
        }
        publickeyAuthenticator = org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator { user, key, _ ->
            val line = authorizedKeyLine
            user == "me" && line != null &&
                KeyUtils.compareKeys(AuthorizedKeyEntry.parseAuthorizedKeyEntry(line).resolvePublicKey(null, PublicKeyEntryResolver.IGNORING), key)
        }
        shellFactory = InteractiveProcessShellFactory.INSTANCE
        subsystemFactories = listOf(SftpSubsystemFactory())
        forwardingFilter = AcceptAllForwardingFilter.INSTANCE
        fileSystemFactory = VirtualFileSystemFactory(root)
    }.also { it.start() }

    val port: Int get() = server.port

    override fun close() {
        server.stop(true)
    }
}
