package pl.dmq.peering.session.ports

import kotlinx.coroutines.flow.Flow

/** The TLS byte stream carrying the control connection. Frames are cut by the caller, not by the transport. */
interface ControlTransport {
    /** Writes [bytes] to the connection. Throws when the connection is gone. */
    suspend fun send(bytes: ByteArray)

    /** Chunks read from the connection in arrival order. Completes when the connection ends. */
    val received: Flow<ByteArray>

    /** Ends the connection. Calling it again does nothing. */
    fun close()

    /** The 65-byte P-256 point from the certificate the peer presented, or null before the TLS handshake finished. */
    fun peerPublicKey(): ByteArray?
}
