package pl.dmq.peering.session.connection

import kotlinx.serialization.json.JsonElement

/**
 * What this client knows before the handshake. [serverKey] is the host key from the TLS certificate the transport
 * received, never a value the host sent. [dialledHostId] is set when the user chose a host by its id. [resumeSource]
 * is the capture source to resume on a reconnect. [clientPlatform] and [videoCodecs] are omitted from the hello when
 * null.
 */
class ClientConfig(
    val clientId: String,
    val clientName: String,
    val dialledHostId: String?,
    val serverKey: ByteArray,
    val resumeSource: JsonElement? = null,
    val clientPlatform: String? = null,
    val videoCodecs: List<String>? = null,
)
