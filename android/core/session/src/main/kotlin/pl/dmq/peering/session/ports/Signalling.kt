package pl.dmq.peering.session.ports

import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

/** The connection to the relay that routes a session to a host it cannot reach directly. */
interface Signalling {
    /** Sends one message to the relay. Throws when the relay connection is gone. */
    suspend fun send(message: RelayClientMessage)

    /** Waits for the next message from the relay. Throws when the relay connection is gone. */
    suspend fun receive(): RelayServerMessage
}
