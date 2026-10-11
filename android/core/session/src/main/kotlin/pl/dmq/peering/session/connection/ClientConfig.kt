package pl.dmq.peering.session.connection

/**
 * What this client knows before the handshake. [serverKey] is the host key from the TLS certificate the transport
 * received, never a value the host sent. [dialledHostId] is set when the user chose a host by its id.
 */
class ClientConfig(
    val clientId: String,
    val clientName: String,
    val dialledHostId: String?,
    val serverKey: ByteArray,
)
