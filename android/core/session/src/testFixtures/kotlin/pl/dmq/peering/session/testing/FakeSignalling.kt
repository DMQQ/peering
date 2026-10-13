package pl.dmq.peering.session.testing

import kotlinx.coroutines.channels.Channel
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

/** Records what the session sends to the relay and answers from a queue of scripted replies. */
class FakeSignalling : Signalling {
    val sent = mutableListOf<RelayClientMessage>()

    private val replies = Channel<RelayServerMessage>(Channel.UNLIMITED)

    fun reply(message: RelayServerMessage) {
        replies.trySend(message).getOrThrow()
    }

    override suspend fun send(message: RelayClientMessage) {
        sent += message
    }

    override suspend fun receive(): RelayServerMessage = replies.receive()
}
