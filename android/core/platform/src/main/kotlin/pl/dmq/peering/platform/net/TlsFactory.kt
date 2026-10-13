package pl.dmq.peering.platform.net

import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import pl.dmq.peering.session.ports.ControlTransport

private const val PROTOCOL = "TLSv1.3"
private const val RELAY_TOKEN_SIZE = 16

/**
 * Opens control connections: TLS 1.3 only, this device's certificate presented, the peer trusted by its pin alone.
 * Blocking calls; run them off the main thread.
 */
class TlsFactory(private val credentials: TlsCredentials) {
    /** [firstPairing] must be set to connect without a [pin]; a known host with no pin is refused rather than trusted. */
    fun open(host: String, port: Int, pin: ByteArray?, firstPairing: Boolean, timeoutMs: Int): ControlTransport {
        val trust = PinningTrustManager(pin, firstPairing)
        val socket = sslContext(trust).socketFactory.createSocket() as SSLSocket
        try {
            socket.tcpNoDelay = true
            socket.enabledProtocols = arrayOf(PROTOCOL)
            socket.connect(InetSocketAddress(host, port), timeoutMs)
            socket.soTimeout = timeoutMs
            socket.startHandshake()
            socket.soTimeout = 0
            return TlsControlTransport(socket, trust)
        } catch (failure: Exception) {
            socket.close()
            throw failure
        }
    }

    /** Writes the relay token on the raw socket first, then starts TLS, so the relay routes the bytes to the host. */
    fun openOverToken(
        raw: Socket,
        token: ByteArray,
        host: String,
        port: Int,
        pin: ByteArray?,
        firstPairing: Boolean,
        timeoutMs: Int,
    ): ControlTransport {
        require(token.size == RELAY_TOKEN_SIZE) { "relay token must be $RELAY_TOKEN_SIZE bytes" }
        try {
            raw.soTimeout = timeoutMs
            raw.getOutputStream().apply {
                write(token)
                flush()
            }
        } catch (failure: Exception) {
            raw.close()
            throw failure
        }
        return layerTls(raw, host, port, PinningTrustManager(pin, firstPairing), timeoutMs)
    }

    private fun sslContext(trust: PinningTrustManager): SSLContext =
        SSLContext.getInstance(PROTOCOL).apply {
            init(arrayOf(ClientKeyManager(credentials)), arrayOf(trust), SecureRandom())
        }

    private fun layerTls(raw: Socket, host: String, port: Int, trust: PinningTrustManager, timeoutMs: Int): ControlTransport {
        try {
            raw.tcpNoDelay = true
            raw.soTimeout = timeoutMs
            val socket = sslContext(trust).socketFactory.createSocket(raw, host, port, true) as? SSLSocket
                ?: throw IllegalStateException("TLS socket factory did not return an SSL socket")
            socket.enabledProtocols = arrayOf(PROTOCOL)
            socket.startHandshake()
            socket.soTimeout = 0
            return TlsControlTransport(socket, trust)
        } catch (failure: Exception) {
            raw.close()
            throw failure
        }
    }
}
