package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientHandshakeState
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.ServerHello
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** How the handshake of one connection ended. */
internal sealed interface HandshakeOutcome {
    data class Ready(val hello: ServerHello) : HandshakeOutcome

    data class Refused(val reason: FailureReason) : HandshakeOutcome

    /** The connection closed, or the host stopped answering, before the handshake finished. [detail] says which and where. */
    data class Lost(val detail: String) : HandshakeOutcome

    /** The user cancelled. Any decline the host needed to hear is already queued. */
    data object Cancelled : HandshakeOutcome
}

/**
 * Drives the client state machine over one connection. Every wait ends when the connection closes, when the user
 * cancels, or when the host has been silent for the state's limit: a host frame gets [FRAME_TIMEOUT], while the six
 * digits and the Mac user's approval get [PAIRING_TIMEOUT], a little over the host's own 120 seconds so its verdict
 * arrives first. The user's own time typing the code is covered by the same limit.
 */
internal class SessionHandshake(
    config: ClientConfig,
    pins: PinStore,
    random: Random,
    private val frames: ReceiveChannel<Frame>,
    private val pairingSecret: ByteArray?,
    private val sendFrame: (Frame) -> Unit,
    private val awaitDecision: suspend (code: String) -> PairingDecision,
) {
    private val machine = ClientStateMachine(config, pins, random)
    private val cancelRequest = CompletableDeferred<Unit>()

    /** Ends the handshake at its next wait, telling the host when it has a pairing waiting on this phone. */
    fun cancel() {
        cancelRequest.complete(Unit)
    }

    private sealed interface Event {
        data class Arrived(val frame: Frame) : Event

        data class Decided(val decision: PairingDecision) : Event

        data object Closed : Event

        data object Cancelled : Event
    }

    suspend fun run(): HandshakeOutcome = coroutineScope { drive() }

    private suspend fun CoroutineScope.drive(): HandshakeOutcome {
        var decision: Deferred<PairingDecision>? = null
        var actions = machine.start()
        while (true) {
            for (action in actions) {
                when (action) {
                    is ClientAction.Send -> sendFrame(action.frame)
                    is ClientAction.ShowCode -> decision = async { awaitDecision(action.code) }
                    is ClientAction.Ready -> return HandshakeOutcome.Ready(action.hello)
                    is ClientAction.Failed -> return HandshakeOutcome.Refused(action.reason)
                    ClientAction.PinRecorded -> Unit
                }
            }
            actions = when (val event = nextEvent(decision)) {
                is Event.Arrived -> machine.onFrame(event.frame)
                is Event.Decided -> {
                    decision = null
                    machine.confirm(event.decision.accepted, event.decision.secret ?: pairingSecret)
                }
                Event.Cancelled -> {
                    decision?.cancel()
                    machine.cancel().forEach { if (it is ClientAction.Send) sendFrame(it.frame) }
                    return HandshakeOutcome.Cancelled
                }
                Event.Closed, null -> {
                    decision?.cancel()
                    return HandshakeOutcome.Lost(lostDetail(silent = event == null))
                }
            }
        }
    }

    private suspend fun nextEvent(decision: Deferred<PairingDecision>?): Event? = withTimeoutOrNull(limit()) {
        select {
            frames.onReceiveCatching { result -> result.getOrNull()?.let(Event::Arrived) ?: Event.Closed }
            if (decision != null) decision.onAwait { Event.Decided(it) }
            cancelRequest.onAwait { Event.Cancelled }
        }
    }

    private fun lostDetail(silent: Boolean): String {
        val what = if (silent) "The host stopped answering" else "The host closed the connection"
        val stage = when (machine.state) {
            ClientHandshakeState.AwaitingUserConfirmation -> "while the pairing code was being entered"
            ClientHandshakeState.AwaitingPairResult -> "while waiting for the Mac to approve the pairing"
            ClientHandshakeState.AwaitingServerCommit, ClientHandshakeState.AwaitingServerReveal -> "during pairing"
            else -> "during the handshake"
        }
        return "$what $stage"
    }

    private fun limit(): Duration = when (machine.state) {
        ClientHandshakeState.AwaitingUserConfirmation, ClientHandshakeState.AwaitingPairResult -> PAIRING_TIMEOUT
        else -> FRAME_TIMEOUT
    }

    private companion object {
        val FRAME_TIMEOUT = 10.seconds
        val PAIRING_TIMEOUT = 125.seconds
    }
}
