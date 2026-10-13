package pl.dmq.peering.sshj

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import pl.dmq.peering.session.testing.FakeSecretStore
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.hostkey.HostKeyPrompt
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshEndpoint
import pl.dmq.peering.ssh.transport.SshConnectRequest
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshFailure
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class SshjTransportTest {
    private val root = Files.createTempDirectory("sshj-test")
    private val known = KnownHostsStore(FakeSecretStore())
    private val asked = mutableListOf<HostKeyPrompt>()
    private val open = mutableListOf<SshConnection>()
    private val servers = mutableListOf<EmbeddedServer>()

    @After
    fun stop() {
        open.forEach { it.runCatching { close() } }
        servers.forEach { it.close() }
        root.toFile().deleteRecursively()
    }

    private fun server(password: String? = "pw", key: String? = null) =
        EmbeddedServer(root, password, key).also { servers += it }

    private fun gate(accept: Boolean = true) = HostKeyGate(known, { 1 }) { prompt ->
        asked += prompt
        accept
    }

    private fun connect(server: EmbeddedServer, credential: SshCredential = SshCredential.Password("pw"), accept: Boolean = true) =
        SshjTransport().connect(SshConnectRequest(SshEndpoint("127.0.0.1", server.port), "me", credential, 10_000), gate(accept))
            .also { open += it }

    private fun failureOf(action: () -> Unit): SshFailure {
        try {
            action()
        } catch (failure: SshFailure) {
            return failure
        }
        fail("expected a failure")
        error("unreachable")
    }

    @Test
    fun aFirstConnectionAsksAboutTheKeyOnceAndRemembersIt() {
        val server = server()
        connect(server).close()
        assertEquals(1, asked.size)
        assertTrue(asked.single().fingerprint.startsWith("SHA256:"))
        connect(server).close()
        assertEquals(1, asked.size)
    }

    @Test
    fun aRefusedKeyIsReportedAsRefusedAndNotAsASignInProblem() {
        val failure = failureOf { connect(server(), accept = false) }
        assertTrue(failure is SshFailure.HostKeyRejected)
    }

    @Test
    fun aServerThatPresentsADifferentKeyThanBeforeIsStoppedBeforeSigningIn() {
        val first = server()
        connect(first).close()
        val endpoint = SshEndpoint("127.0.0.1", first.port)
        val key = known.host(endpoint)!!
        val impostor = EmbeddedServer(root, password = "pw", algorithm = "RSA").also { servers += it }
        known.record(SshEndpoint("127.0.0.1", impostor.port), key.algorithm, java.util.Base64.getDecoder().decode(key.publicKey), 1)
        val failure = failureOf { connect(impostor) }
        assertTrue(failure is SshFailure.HostKeyChanged)
        assertEquals("ssh-rsa", (failure as SshFailure.HostKeyChanged).presented.algorithm)
    }

    @Test
    fun aWrongPasswordIsASignInFailure() {
        val failure = failureOf { connect(server(), SshCredential.Password("nope")) }
        assertTrue(failure is SshFailure.AuthenticationFailed)
    }

    @Test
    fun aGeneratedKeySignsIn() {
        val pair = SshKeys.generate("phone")
        val connection = connect(server(password = null, key = pair.publicKey), SshCredential.Key(pair))
        assertTrue(connection.isOpen)
    }

    @Test
    fun aKeyThePasswordOnlyServerDoesNotKnowIsRefused() {
        val failure = failureOf { connect(server(), SshCredential.Key(SshKeys.generate())) }
        assertTrue(failure is SshFailure.AuthenticationFailed)
    }

    @Test
    fun aClosedPortIsReportedInWords() {
        val port = ServerSocket(0).use { it.localPort }
        val failure = failureOf {
            SshjTransport().connect(SshConnectRequest(SshEndpoint("127.0.0.1", port), "me", SshCredential.Password("pw"), 3_000), gate())
        }
        assertTrue(failure is SshFailure.Transport)
    }

    @Test
    fun aPortThatAcceptsAndNeverSpeaksTimesOutInsteadOfHanging() {
        ServerSocket(0).use { silent ->
            val failure = failureOf {
                SshjTransport().connect(SshConnectRequest(SshEndpoint("127.0.0.1", silent.localPort), "me", SshCredential.Password("pw"), 1_500), gate())
            }
            assertTrue(failure is SshFailure.TimedOut)
        }
    }

    @Test
    fun aShellRunsCommandsAndReportsItsExitStatus() {
        val connection = connect(server())
        val output = StringBuffer()
        val ended = CountDownLatch(1)
        var status: Int? = -1
        val shell = connection.openShell(80, 24, { output.append(it.decodeToString()) }, { status = it; ended.countDown() })
        shell.write("echo marker-$((6*7))\n".encodeToByteArray())
        shell.resize(120, 40)
        shell.write("exit 3\n".encodeToByteArray())
        assertTrue("output: $output", ended.await(10, TimeUnit.SECONDS))
        assertTrue(output.toString(), output.contains("marker-42"))
        assertEquals(3, status)
    }

    @Test
    fun sftpListsWritesReadsRenamesAndDeletes() {
        File(root.toFile(), "docs").mkdir()
        val sftp = connect(server()).sftp()
        assertEquals(listOf("docs"), sftp.list("/").entries.map { it.name })
        val upload = sftp.beginWrite("/docs/a.txt")
        upload.write("hello ".encodeToByteArray())
        upload.write("world".encodeToByteArray())
        assertEquals(11L, upload.finish())
        val piece = sftp.read("/docs/a.txt", 6, 100)
        assertEquals("world", piece.bytes.decodeToString())
        assertEquals(11L, piece.totalBytes)
        sftp.rename("/docs/a.txt", "b.txt")
        sftp.createFolder("/docs/sub")
        sftp.createFile("/docs/sub/c")
        val listing = sftp.list("/docs").entries
        assertEquals(setOf("b.txt", "sub"), listing.map { it.name }.toSet())
        assertTrue(listing.single { it.name == "sub" }.isDirectory)
        assertTrue(listing.single { it.name == "b.txt" }.permissions.startsWith("-rw"))
        assertTrue(sftp.delete("/docs").contains("3"))
        assertTrue(sftp.list("/").entries.isEmpty())
    }

    @Test
    fun aMissingFileIsASentenceNotAStackTrace() {
        val sftp = connect(server()).sftp()
        val failure = failureOf { sftp.read("/nope", 0, 10) }
        assertEquals("That path does not exist.", (failure as SshFailure.Browse).reason)
    }

    @Test
    fun aForwardCarriesBytesToTheFarEndAndBack() {
        val target = ServerSocket(0)
        thread(isDaemon = true) {
            target.accept().use { socket ->
                val byte = socket.getInputStream().read()
                socket.getOutputStream().write(byte + 1)
            }
        }
        val local = ServerSocket(0).use { it.localPort }
        val handle = connect(server()).forward(local, "127.0.0.1", target.localPort)
        Socket("127.0.0.1", local).use { client ->
            client.soTimeout = 10_000
            client.getOutputStream().write(41)
            assertEquals(42, client.getInputStream().read())
        }
        handle.close()
        target.close()
    }

    @Test
    fun aPortAlreadyInUseFailsTheForwardAlone() {
        val busy = ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val connection = connect(server())
        val failure = failureOf { connection.forward(busy.localPort, "127.0.0.1", 1) }
        assertTrue(failure is SshFailure.Forward)
        assertTrue(connection.isOpen)
        busy.close()
    }

    @Test
    fun aServerThatGoesAwayIsReportedAsLostButClosingIsNot() {
        val server = server()
        val kept = connect(server)
        val closed = connect(server)
        val lost = CountDownLatch(1)
        var wrongly = false
        kept.onLost { lost.countDown() }
        closed.onLost { wrongly = true }
        closed.close()
        servers.remove(server)
        server.close()
        assertTrue(lost.await(10, TimeUnit.SECONDS))
        assertTrue(!wrongly)
    }
}
