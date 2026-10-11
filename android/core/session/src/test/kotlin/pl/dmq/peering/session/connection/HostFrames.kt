package pl.dmq.peering.session.connection

import kotlinx.serialization.KSerializer
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PairResult
import pl.dmq.peering.wire.PairingCommit
import pl.dmq.peering.wire.PairingReveal
import pl.dmq.peering.wire.PairingSas
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.toBase64

/** The frames a Mac sends during the handshake, built the way the Mac builds them. */
internal object HostFrames {
    const val HOST_ID = "MAC-STUDIO-01"
    const val CLIENT_ID = "client-1"

    val hostKey = ByteArray(65) { 0x7 }
    val hostEphemeral = ByteArray(65) { 0x22 }
    val hostNonce = ByteArray(32) { 0x33 }

    fun serverHello(
        serverId: String = HOST_ID,
        version: Int = PROTOCOL_VERSION,
        alreadyPaired: Boolean = false,
    ): Frame = json(
        MessageKind.ServerHello,
        ServerHello.serializer(),
        ServerHello(
            serverID = serverId,
            hostName = "Studio",
            protocolVersion = version,
            alreadyPaired = alreadyPaired,
        ),
    )

    fun commit(ephemeral: ByteArray = hostEphemeral, nonce: ByteArray = hostNonce): Frame = json(
        MessageKind.PairCommit,
        PairingCommit.serializer(),
        PairingCommit(PairingSas.commitment(ephemeral, nonce).toBase64()),
    )

    fun reveal(ephemeral: ByteArray = hostEphemeral, nonce: ByteArray = hostNonce): Frame = json(
        MessageKind.PairReveal,
        PairingReveal.serializer(),
        PairingReveal(ephemeral.toBase64(), nonce.toBase64()),
    )

    fun pairResult(accepted: Boolean, reason: String? = null): Frame = json(
        MessageKind.PairResult,
        PairResult.serializer(),
        PairResult(accepted, reason),
    )

    fun malformed(kind: MessageKind): Frame = Frame(kind, "not json".toByteArray())

    private fun <T> json(kind: MessageKind, serializer: KSerializer<T>, value: T): Frame =
        Frame(kind, WireJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))
}
