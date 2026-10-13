package pl.dmq.peering.session.connection

import kotlinx.serialization.KSerializer
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.ConnectionRole
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.WireJson

/** Builds the frames the client sends during the handshake, and reads the JSON they carry back. */
internal object HandshakeFrames {
    fun connectionRole(): Frame = Frame(MessageKind.ConnectionRole, byteArrayOf(ConnectionRole.Control.byte.toByte()))

    fun clientHello(config: ClientConfig, knowsHost: Boolean): Frame = json(
        MessageKind.ClientHello,
        ClientHello.serializer(),
        ClientHello(
            clientID = config.clientId,
            clientName = config.clientName,
            protocolVersion = PROTOCOL_VERSION,
            wantsPairing = !knowsHost,
            supportsClipboardImages = true,
            supportsTextFocus = true,
            supportsFieldState = true,
            supportsPointerReport = true,
            supportsAgentChat = true,
            supportsAgentPermissionModes = true,
            supportsAgentUsage = true,
            lostPairing = if (config.dialledHostId != null && !knowsHost) true else null,
            resumeSource = config.resumeSource.takeIf { knowsHost },
            clientPlatform = config.clientPlatform,
            videoCodecs = config.videoCodecs,
        ),
    )

    fun <T> json(kind: MessageKind, serializer: KSerializer<T>, value: T): Frame =
        Frame(kind, WireJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))

    fun <T> decode(frame: Frame, serializer: KSerializer<T>): T? = parsed {
        WireJson.decodeFromString(serializer, frame.payload.decodeToString())
    }

    /** Wire data that does not parse is an expected outcome here, reported as a failure rather than thrown. */
    fun <T> parsed(read: () -> T): T? = try {
        read()
    } catch (error: IllegalArgumentException) {
        null
    }
}
