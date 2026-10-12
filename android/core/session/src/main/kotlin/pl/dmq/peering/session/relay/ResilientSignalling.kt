package pl.dmq.peering.session.relay

import java.io.IOException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.ReconnectLadder
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

/**
 * The relay's signalling connection, opened again when it drops. [open] returns a connected [Signalling] and fails with an
 * [IOException] when the relay cannot be reached. Requests are serialised, so replies are never read by the wrong request.
 * A request that fails with an [IOException] runs once more on a new connection, unless it is not idempotent and
 * already sent something; opening waits on the reconnect ladder between attempts, and a failure that outlasts the
 * ladder is thrown. Every open and every request is bounded by [timeout]; a connection that does not answer in time
 * is dropped and the request fails with an [IOException].
 */
class ResilientSignalling(
    private val open: suspend () -> Signalling,
    private val pause: suspend (Duration) -> Unit = { delay(it) },
    private val timeout: Duration = 10.seconds,
) : Signalling {
    private val lock = Mutex()

    @Volatile
    private var connection: Signalling? = null

    /** A lone send or receive is a request of its own, so it gets the same reopen-and-retry as [exchange]. */
    override suspend fun send(message: RelayClientMessage) = exchange { send(message) }

    /** Bounded to [timeout] (10 s by default): a lone receive on a quiet connection fails with an [IOException]. */
    override suspend fun receive(): RelayServerMessage = exchange { receive() }

    override suspend fun <T> exchange(idempotent: Boolean, block: suspend Signalling.() -> T): T =
        lock.withLock { runWithRetry(idempotent, block) }

    override fun drop() {
        val stale = connection
        connection = null
        stale?.drop()
    }

    private suspend fun <T> runWithRetry(idempotent: Boolean, block: suspend Signalling.() -> T): T {
        val ladder = ReconnectLadder()
        var retried = false
        while (true) {
            val tracked = SentTracker(connectionFrom(ladder))
            try {
                return bounded { tracked.block() }
            } catch (dropped: IOException) {
                drop()
                if (retried || (!idempotent && tracked.sent)) throw dropped
                retried = true
            }
        }
    }

    private suspend fun connectionFrom(ladder: ReconnectLadder): Signalling {
        connection?.let { return it }
        while (true) {
            try {
                return bounded(open).also { connection = it }
            } catch (unreachable: IOException) {
                val step = ladder.next() ?: throw unreachable
                pause(step)
            }
        }
    }

    private suspend fun <T> bounded(block: suspend () -> T): T = try {
        withTimeout(timeout) { block() }
    } catch (expired: TimeoutCancellationException) {
        throw IOException("the relay did not answer in $timeout", expired)
    }

    private class SentTracker(private val delegate: Signalling) : Signalling {
        @Volatile
        var sent = false
            private set

        override suspend fun send(message: RelayClientMessage) {
            delegate.send(message)
            sent = true
        }

        override suspend fun receive(): RelayServerMessage = delegate.receive()
    }
}
