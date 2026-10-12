package pl.dmq.peering.platform.net

import java.net.InetAddress
import java.security.KeyStore
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** A loopback TLS 1.3 server that asks for a client certificate and then closes each accepted connection. */
private class LoopbackServer(identity: PeerCredentials) : AutoCloseable {
    private val context = SSLContext.getInstance("TLSv1.3").apply {
        val store = KeyStore.getInstance("PKCS12").apply {
            load(null, null)
            setKeyEntry(PeerCredentials.ALIAS, identity.privateKey(), PeerCredentials.PASSWORD.toCharArray(), identity.certificateChain().toTypedArray())
        }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(store, PeerCredentials.PASSWORD.toCharArray())
        }
        init(keys.keyManagers, arrayOf(PinningTrustManager(pin = null, firstPairing = true)), null)
    }
    private val socket: SSLServerSocket = context.serverSocketFactory
        .createServerSocket(0, 1, InetAddress.getLoopbackAddress()) as SSLServerSocket
    private val executor = Executors.newSingleThreadExecutor()

    val port: Int get() = socket.localPort

    init {
        socket.enabledProtocols = arrayOf("TLSv1.3")
        socket.needClientAuth = false
        socket.wantClientAuth = true
    }

    fun acceptOnce() = executor.submit(Callable {
        (socket.accept() as SSLSocket).use { connection ->
            connection.enabledProtocols = arrayOf("TLSv1.3")
            connection.startHandshake()
        }
    })

    override fun close() {
        socket.close()
        executor.shutdownNow()
    }
}

class TlsFactoryLoopbackTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val timeoutMs = 5_000

    @Test
    fun firstPairingConnectsAndRecordsTheServerKey() {
        val server = PeerCredentials.generate(folder.root, "host")
        val client = PeerCredentials.generate(folder.root, "phone")
        LoopbackServer(server).use { loopback ->
            val accepted = loopback.acceptOnce()

            val transport = TlsFactory(client).open("127.0.0.1", loopback.port, pin = null, firstPairing = true, timeoutMs = timeoutMs)
            accepted.get(timeoutMs.toLong(), TimeUnit.MILLISECONDS)

            assertArrayEquals(server.point, transport.peerPublicKey())
            transport.close()
        }
    }

    @Test
    fun pinnedMatchingKeyConnects() {
        val server = PeerCredentials.generate(folder.root, "host")
        val client = PeerCredentials.generate(folder.root, "phone")
        LoopbackServer(server).use { loopback ->
            val accepted = loopback.acceptOnce()

            val transport = TlsFactory(client).open("127.0.0.1", loopback.port, pin = server.point, firstPairing = false, timeoutMs = timeoutMs)
            accepted.get(timeoutMs.toLong(), TimeUnit.MILLISECONDS)

            assertArrayEquals(server.point, transport.peerPublicKey())
            transport.close()
        }
    }

    @Test
    fun pinnedMismatchIsRefused() {
        val server = PeerCredentials.generate(folder.root, "host")
        val impostor = PeerCredentials.generate(folder.root, "impostor")
        val client = PeerCredentials.generate(folder.root, "phone")
        LoopbackServer(impostor).use { loopback ->
            loopback.acceptOnce()

            assertThrows(SSLHandshakeException::class.java) {
                TlsFactory(client).open("127.0.0.1", loopback.port, pin = server.point, firstPairing = false, timeoutMs = timeoutMs)
            }
        }
    }

    @Test
    fun aMissingPinWithoutTheFirstPairingFlagFailsBeforeAnyConnection() {
        val client = PeerCredentials.generate(folder.root, "phone")

        assertThrows(IllegalArgumentException::class.java) {
            TlsFactory(client).open("127.0.0.1", 1, pin = null, firstPairing = false, timeoutMs = timeoutMs)
        }
    }
}
