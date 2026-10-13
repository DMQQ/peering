package pl.dmq.peering.session.preview

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader
import pl.dmq.peering.wire.PreviewProxyCommand
import pl.dmq.peering.wire.PreviewProxyEvent
import pl.dmq.peering.wire.PreviewProxyRequest
import pl.dmq.peering.wire.toBase64

/**
 * Asks the computer to fetch pages from its own loopback and hands each answer back to the request that is waiting
 * for it. [transmit] delivers a command on the current link and returns false when there is none. When the link goes,
 * [failAll] ends every open request with a reason instead of leaving it hanging. A response that grows past
 * [maxResponseBytes] is ended with [PreviewFailure.TOO_LARGE] and the computer is told to stop sending it.
 */
class PreviewProxyClient(
    private val maxResponseBytes: Long = PreviewPolicy.MAX_RESPONSE_BYTES,
    private val transmit: (PreviewProxyCommand) -> Boolean,
) {
    private val lock = Any()
    private val waiting = HashMap<Long, SendChannel<PreviewProxyEvent>>()
    private var lastId = 0L

    /**
     * The answer to one request: a head, bodies and an end, or a failure, and then the flow finishes. Collecting it
     * to the end is not required: cancelling the collection tells the computer to stop.
     */
    fun fetch(
        port: Int,
        method: String,
        target: String,
        headers: List<PreviewHeader> = emptyList(),
        body: ByteArray? = null,
    ): Flow<PreviewProxyEvent> = channelFlow {
        val request = PreviewProxyRequest(0, port, method, target, headers, body?.toBase64())
        val refusal = PreviewPolicy.refusal(request) ?: bodyRefusal(body)
        if (refusal != null) {
            send(PreviewProxyEvent.Failure(0, refusal))
            return@channelFlow
        }
        val mailbox = Channel<PreviewProxyEvent>(Channel.UNLIMITED)
        val id = register(mailbox)
        if (!transmit(PreviewProxyCommand.Fetch(request.copy(id = id)))) {
            forget(id)
            send(PreviewProxyEvent.Failure(id, PreviewFailure.DISCONNECTED))
            return@channelFlow
        }
        var received = 0L
        try {
            for (event in mailbox) {
                if (event is PreviewProxyEvent.Body) {
                    received += event.data.length / BASE64_GROUP * BYTES_PER_GROUP
                    if (received > maxResponseBytes) {
                        send(PreviewProxyEvent.Failure(id, PreviewFailure.TOO_LARGE))
                        return@channelFlow
                    }
                }
                send(event)
            }
        } finally {
            if (forget(id)) transmit(PreviewProxyCommand.Cancel(id))
        }
    }

    fun onEvent(event: PreviewProxyEvent) {
        val mailbox = synchronized(lock) { if (event.isFinal) waiting.remove(event.id) else waiting[event.id] } ?: return
        mailbox.trySend(event)
        if (event.isFinal) mailbox.close()
    }

    /** The link to the computer is gone. */
    fun failAll(reason: PreviewFailure = PreviewFailure.DISCONNECTED) {
        val open = synchronized(lock) { waiting.toMap().also { waiting.clear() } }
        for ((id, mailbox) in open) {
            mailbox.trySend(PreviewProxyEvent.Failure(id, reason))
            mailbox.close()
        }
    }

    private fun bodyRefusal(body: ByteArray?): PreviewFailure? =
        if (body != null && body.size > PreviewPolicy.MAX_REQUEST_BODY_BYTES) PreviewFailure.TOO_LARGE else null

    private fun register(mailbox: SendChannel<PreviewProxyEvent>): Long = synchronized(lock) {
        lastId++
        waiting[lastId] = mailbox
        lastId
    }

    /** Whether the request was still open, which decides if the computer needs telling to stop. */
    private fun forget(id: Long): Boolean = synchronized(lock) { waiting.remove(id) != null }

    private companion object {
        const val BASE64_GROUP = 4
        const val BYTES_PER_GROUP = 3
    }
}
