package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.ServerHello

/** What the caller must do after the state machine moved. */
sealed interface ClientAction {
    /** Write this frame to the control connection. */
    data class Send(val frame: Frame) : ClientAction

    /** Show the six digits and ask the user to confirm they match the host's. */
    data class ShowCode(val code: String) : ClientAction

    /** The handshake is complete and the session may start. */
    data class Ready(val hello: ServerHello) : ClientAction

    /** The handshake ended without a session. */
    data class Failed(val reason: FailureReason) : ClientAction

    /** The host key was saved, so the pairing is durable. */
    data object PinRecorded : ClientAction
}
