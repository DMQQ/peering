package pl.dmq.peering.session.controller

import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello
import kotlin.time.Duration.Companion.seconds

/** How the handshake of one connection ended. */
internal sealed interface HandshakeOutcome {
    data class Ready(val hello: ServerHello) : HandshakeOutcome

    data class Refused(val reason: FailureReason) : HandshakeOutcome

    /** The connection closed, or the host stopped answering, before the handshake finished. */
    data object Lost : HandshakeOutcome
}

/**
 * Drives the client state machine over one connection. Each host frame is waited for with [HANDSHAKE_TIMEOUT]; the wait
 * for the user's answer to a six digit code is not timed, since a person may take as long as they like.
 */
internal class SessionHandshake(
    config: ClientConfig,
    pins: PinStore,
    random: Random,
    private val frames: ReceiveChannel<Frame>,
    private val pairingSecret: ByteArray?,
    private val resumeSource: JsonElement?,
    private val sendFrame: (Frame) -> Unit,
    private val awaitDecision: suspend (code: String) -> Boolean,
) {
    private val machine = ClientStateMachine(config, pins, random)

    suspend fun run(): HandshakeOutcome {
        consume(machine.start())?.let { return it }
        while (true) {
            val frame = withTimeoutOrNull(HANDSHAKE_TIMEOUT) { frames.receiveCatching().getOrNull() }
                ?: return HandshakeOutcome.Lost
            consume(machine.onFrame(frame))?.let { return it }
        }
    }

    private suspend fun consume(actions: List<ClientAction>): HandshakeOutcome? {
        for (action in actions) {
            when (action) {
                is ClientAction.Send -> sendFrame(withResumeSource(action.frame))
                is ClientAction.ShowCode -> {
                    val accepted = awaitDecision(action.code)
                    return consume(machine.confirm(accepted, pairingSecret))
                }
                is ClientAction.Ready -> return HandshakeOutcome.Ready(action.hello)
                is ClientAction.Failed -> return HandshakeOutcome.Refused(action.reason)
                ClientAction.PinRecorded -> Unit
            }
        }
        return null
    }

    /** The state machine does not carry the resume source, so the client hello is rewritten with it on a reconnect. */
    private fun withResumeSource(frame: Frame): Frame {
        val source = resumeSource ?: return frame
        if (frame.kind != MessageKind.ClientHello) return frame
        val hello = HandshakeFrames.decode(frame, ClientHello.serializer()) ?: return frame
        return HandshakeFrames.json(MessageKind.ClientHello, ClientHello.serializer(), hello.copy(resumeSource = source))
    }

    private companion object {
        val HANDSHAKE_TIMEOUT = 10.seconds
    }
}
