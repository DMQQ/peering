package pl.dmq.peering.session.flows

import kotlinx.serialization.KSerializer
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.PairConfirm
import pl.dmq.peering.wire.PairResult
import pl.dmq.peering.wire.PairingCommit
import pl.dmq.peering.wire.PairingReveal
import pl.dmq.peering.wire.PairingSas
import pl.dmq.peering.wire.PairingTranscript
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.fromBase64
import pl.dmq.peering.wire.toBase64

/**
 * The host side of the handshake, written from protocol.md with the wire primitives. It answers what it is sent,
 * one frame at a time, and records what the phone told it. [refusal] makes it decline every confirmation; [qrSecret]
 * makes it check the proof a scanned code carries.
 */
class ScriptedPairingHost(
    private val hostId: String = HOST_ID,
    private val hostKey: ByteArray = HOST_KEY,
    private val alreadyPaired: Boolean = false,
    private val qrSecret: ByteArray? = null,
    private val refusal: String? = null,
) {
    private val inbound = FrameDecoder()
    private val hostEphemeral = ByteArray(EPHEMERAL_SIZE) { 0x22 }.also { it[0] = UNCOMPRESSED_POINT }
    private val hostNonce = ByteArray(NONCE_SIZE) { 0x33 }

    private var clientID: String? = null
    private var clientCommitment: ByteArray? = null
    private var clientEphemeral: ByteArray? = null
    private var clientNonce: ByteArray? = null
    private var transcript: PairingTranscript? = null

    /** The six digits the host shows, once the phone has revealed its key. */
    var shownCode: String? = null
        private set

    /** Every kind of frame the phone has sent, in order. */
    val receivedKinds = mutableListOf<MessageKind>()

    /** The confirmation the phone sent, when it sent one. */
    var confirmation: PairConfirm? = null
        private set

    /** Takes bytes from the phone and returns the frames the host answers with, in order. */
    fun receive(bytes: ByteArray): List<Frame> {
        inbound.push(bytes)
        val replies = mutableListOf<Frame>()
        while (true) {
            val frame = inbound.next() ?: break
            receivedKinds += frame.kind
            replies += respond(frame)
        }
        return replies
    }

    private fun respond(frame: Frame): List<Frame> = when (frame.kind) {
        MessageKind.ClientHello -> listOf(answerHello(decode(frame, ClientHello.serializer())))
        MessageKind.PairCommit -> answerCommit(decode(frame, PairingCommit.serializer()))
        MessageKind.PairReveal -> answerReveal(decode(frame, PairingReveal.serializer()))
        MessageKind.PairConfirm -> answerConfirm(decode(frame, PairConfirm.serializer()))
        else -> emptyList()
    }

    private fun answerHello(hello: ClientHello): Frame {
        clientID = hello.clientID
        val serverHello = ServerHello(
            serverID = hostId,
            hostName = "Studio",
            protocolVersion = PROTOCOL_VERSION,
            alreadyPaired = alreadyPaired,
        )
        return json(MessageKind.ServerHello, ServerHello.serializer(), serverHello)
    }

    private fun answerCommit(commit: PairingCommit): List<Frame> {
        clientCommitment = commit.commitmentBytes
        val hostCommit = PairingCommit(PairingSas.commitment(hostEphemeral, hostNonce).toBase64())
        return listOf(json(MessageKind.PairCommit, PairingCommit.serializer(), hostCommit))
    }

    private fun answerReveal(reveal: PairingReveal): List<Frame> {
        val ephemeral = reveal.ephemeralPublicKeyBytes
        val nonce = reveal.nonceBytes
        check(PairingSas.verifyCommitment(checkNotNull(clientCommitment), ephemeral, nonce)) {
            "the phone revealed a key that does not match its commitment"
        }
        clientEphemeral = ephemeral
        clientNonce = nonce
        val pairing = PairingTranscript(
            protocolVersion = PROTOCOL_VERSION,
            clientId = checkNotNull(clientID),
            serverId = hostId,
            clientEphemeralPublicKey = ephemeral,
            serverEphemeralPublicKey = hostEphemeral,
            clientNonce = nonce,
            serverNonce = hostNonce,
            serverIdentityPublicKey = hostKey,
        )
        transcript = pairing
        shownCode = pairing.code()
        val hostReveal = PairingReveal(hostEphemeral.toBase64(), hostNonce.toBase64())
        return listOf(json(MessageKind.PairReveal, PairingReveal.serializer(), hostReveal))
    }

    private fun answerConfirm(confirm: PairConfirm): List<Frame> {
        confirmation = confirm
        if (!confirm.accepted) return emptyList()
        return listOf(json(MessageKind.PairResult, PairResult.serializer(), verdict(confirm)))
    }

    private fun verdict(confirm: PairConfirm): PairResult {
        refusal?.let { return PairResult(accepted = false, reason = it) }
        val secret = qrSecret ?: return PairResult(accepted = true)
        val proof = confirm.proofBytes ?: return PairResult(accepted = true)
        return if (checkNotNull(transcript).verifyProof(proof, secret)) {
            PairResult(accepted = true)
        } else {
            PairResult(accepted = false, reason = "The code does not match this Mac")
        }
    }

    private fun <T> decode(frame: Frame, serializer: KSerializer<T>): T =
        WireJson.decodeFromString(serializer, frame.payload.decodeToString())

    private fun <T> json(kind: MessageKind, serializer: KSerializer<T>, value: T): Frame =
        Frame(kind, WireJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))

    companion object {
        const val HOST_ID = "MAC-STUDIO-01"
        val HOST_KEY = ByteArray(65) { 0x7 }
        private const val EPHEMERAL_SIZE = 65
        private const val NONCE_SIZE = 32
        private const val UNCOMPRESSED_POINT: Byte = 0x04
    }
}
