package pl.dmq.peering.session.connection

import java.security.MessageDigest
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.PairConfirm
import pl.dmq.peering.wire.PairResult
import pl.dmq.peering.wire.PairingCommit
import pl.dmq.peering.wire.PairingReveal
import pl.dmq.peering.wire.PairingSas
import pl.dmq.peering.wire.PairingTranscript
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.toBase64

/**
 * The client side of the handshake and pairing (protocol.md sections 5 and 6), with no I/O of its own. The caller
 * writes the frames it returns, feeds in what arrives, and acts on the [ClientAction]s. Frames that arrive after
 * [ClientHandshakeState.Ready] belong to the session and are ignored here.
 */
class ClientStateMachine(
    private val config: ClientConfig,
    private val pins: PinStore,
    private val random: Random,
) {
    var state: ClientHandshakeState = ClientHandshakeState.Idle
        private set

    private var serverHello: ServerHello? = null
    private var clientEphemeral: ByteArray? = null
    private var clientNonce: ByteArray? = null
    private var remoteCommitment: ByteArray? = null
    private var transcript: PairingTranscript? = null

    /** Sends the connection role and the client hello. Call once, before any frame. */
    fun start(): List<ClientAction> {
        check(state == ClientHandshakeState.Idle) { "the handshake was already started" }
        val knowsHost = config.dialledHostId?.let { pins.pin(it) != null } ?: false
        state = ClientHandshakeState.AwaitingServerHello
        return listOf(
            ClientAction.Send(HandshakeFrames.connectionRole()),
            ClientAction.Send(HandshakeFrames.clientHello(config, knowsHost)),
        )
    }

    fun onFrame(frame: Frame): List<ClientAction> = when (state) {
        ClientHandshakeState.AwaitingServerHello -> onServerHello(frame)
        ClientHandshakeState.AwaitingServerCommit -> onServerCommit(frame)
        ClientHandshakeState.AwaitingServerReveal -> onServerReveal(frame)
        ClientHandshakeState.AwaitingPairResult -> onPairResult(frame)
        ClientHandshakeState.Idle,
        ClientHandshakeState.AwaitingUserConfirmation,
        ClientHandshakeState.Ready,
        ClientHandshakeState.Failed,
        -> emptyList()
    }

    /**
     * The user's decision on the six digits. [secret] is the QR code's secret when the digits were scanned, and null
     * when they were typed. Ignored unless the user is being asked.
     */
    fun confirm(accepted: Boolean, secret: ByteArray?): List<ClientAction> {
        if (state != ClientHandshakeState.AwaitingUserConfirmation) return emptyList()
        if (!accepted) {
            state = ClientHandshakeState.Failed
            return listOf(
                ClientAction.Send(HandshakeFrames.json(MessageKind.PairConfirm, PairConfirm.serializer(), PairConfirm(false))),
                ClientAction.Failed(FailureReason.PairingDeclined),
            )
        }
        state = ClientHandshakeState.AwaitingPairResult
        val proof = secret?.let { checkNotNull(transcript).proof(it).toBase64() }
        return listOf(
            ClientAction.Send(HandshakeFrames.json(MessageKind.PairConfirm, PairConfirm.serializer(), PairConfirm(true, proof))),
        )
    }

    private fun onServerHello(frame: Frame): List<ClientAction> {
        if (frame.kind != MessageKind.ServerHello) return fail(FailureReason.UnexpectedFrame(frame.kind, "serverHello"))
        val hello = HandshakeFrames.decode(frame, ServerHello.serializer())
            ?: return fail(FailureReason.MalformedMessage(frame.kind))
        if (hello.protocolVersion != PROTOCOL_VERSION) {
            return fail(FailureReason.ProtocolMismatch(PROTOCOL_VERSION, hello.protocolVersion))
        }
        val dialled = config.dialledHostId
        if (dialled != null && hello.serverID != dialled) {
            return fail(FailureReason.HostIdMismatch(dialled, hello.serverID))
        }
        serverHello = hello

        val pin = pins.pin(hello.serverID)
        if (pin != null && !MessageDigest.isEqual(pin, config.serverKey)) {
            return fail(FailureReason.PinMismatch(hello.serverID))
        }
        if (pin == null && hello.alreadyPaired) {
            return fail(FailureReason.NoPinOnFile(hello.serverID))
        }
        return if (hello.alreadyPaired) becomeReady(hello) else beginPairing()
    }

    private fun beginPairing(): List<ClientAction> {
        val ephemeral = random.bytes(EPHEMERAL_SIZE).also { it[0] = UNCOMPRESSED_POINT }
        val nonce = random.bytes(NONCE_SIZE)
        clientEphemeral = ephemeral
        clientNonce = nonce
        state = ClientHandshakeState.AwaitingServerCommit
        val commitment = PairingSas.commitment(ephemeral, nonce).toBase64()
        return listOf(
            ClientAction.Send(HandshakeFrames.json(MessageKind.PairCommit, PairingCommit.serializer(), PairingCommit(commitment))),
        )
    }

    private fun onServerCommit(frame: Frame): List<ClientAction> {
        if (frame.kind != MessageKind.PairCommit) return fail(FailureReason.UnexpectedFrame(frame.kind, "pairCommit"))
        val commit = HandshakeFrames.decode(frame, PairingCommit.serializer())
            ?: return fail(FailureReason.MalformedMessage(frame.kind))
        remoteCommitment = HandshakeFrames.parsed { commit.commitmentBytes }
            ?: return fail(FailureReason.MalformedMessage(frame.kind))

        state = ClientHandshakeState.AwaitingServerReveal
        val reveal = PairingReveal(
            ephemeralPublicKey = checkNotNull(clientEphemeral).toBase64(),
            nonce = checkNotNull(clientNonce).toBase64(),
        )
        return listOf(ClientAction.Send(HandshakeFrames.json(MessageKind.PairReveal, PairingReveal.serializer(), reveal)))
    }

    private fun onServerReveal(frame: Frame): List<ClientAction> {
        if (frame.kind != MessageKind.PairReveal) return fail(FailureReason.UnexpectedFrame(frame.kind, "pairReveal"))
        val reveal = HandshakeFrames.decode(frame, PairingReveal.serializer())
            ?: return fail(FailureReason.MalformedMessage(frame.kind))
        val serverEphemeral = HandshakeFrames.parsed { reveal.ephemeralPublicKeyBytes }
            ?: return fail(FailureReason.MalformedMessage(frame.kind))
        val serverNonce = HandshakeFrames.parsed { reveal.nonceBytes }
            ?: return fail(FailureReason.MalformedMessage(frame.kind))

        if (!PairingSas.verifyCommitment(checkNotNull(remoteCommitment), serverEphemeral, serverNonce)) {
            return fail(FailureReason.CommitmentMismatch)
        }

        val pairing = PairingTranscript(
            protocolVersion = PROTOCOL_VERSION,
            clientId = config.clientId,
            serverId = checkNotNull(serverHello).serverID,
            clientEphemeralPublicKey = checkNotNull(clientEphemeral),
            serverEphemeralPublicKey = serverEphemeral,
            clientNonce = checkNotNull(clientNonce),
            serverNonce = serverNonce,
            serverIdentityPublicKey = config.serverKey,
        )
        transcript = pairing
        state = ClientHandshakeState.AwaitingUserConfirmation
        return listOf(ClientAction.ShowCode(pairing.code()))
    }

    private fun onPairResult(frame: Frame): List<ClientAction> {
        if (frame.kind != MessageKind.PairResult) return fail(FailureReason.UnexpectedFrame(frame.kind, "pairResult"))
        val result = HandshakeFrames.decode(frame, PairResult.serializer())
            ?: return fail(FailureReason.MalformedMessage(frame.kind))
        if (!result.accepted) return fail(FailureReason.PairingRefused(result.reason))

        val hello = checkNotNull(serverHello)
        if (!pins.record(hello.serverID, config.serverKey)) return fail(FailureReason.PairingNotSaved)
        return becomeReady(hello, pinRecorded = true)
    }

    private fun becomeReady(hello: ServerHello, pinRecorded: Boolean = false): List<ClientAction> {
        state = ClientHandshakeState.Ready
        val ready = ClientAction.Ready(hello)
        return if (pinRecorded) listOf(ClientAction.PinRecorded, ready) else listOf(ready)
    }

    private fun fail(reason: FailureReason): List<ClientAction> {
        state = ClientHandshakeState.Failed
        return listOf(ClientAction.Failed(reason))
    }

    private companion object {
        const val EPHEMERAL_SIZE = 65
        const val NONCE_SIZE = 32

        /** The leading byte of an uncompressed P-256 point, so the ephemeral key has the shape the host expects. */
        const val UNCOMPRESSED_POINT: Byte = 0x04
    }
}
