package pl.dmq.peering.session.relay

import java.io.IOException
import kotlin.time.Duration
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
 * A request that fails with an [IOException] runs once more on a new connection; opening waits on the reconnect ladder
 * between attempts, and a failure that outlasts the ladder is thrown.
 */
class ResilientSignalling(
    private val open: suspend () -> Signalling,
    private val pause: suspend (Duration) -> Unit = { delay(it) },
) : Signalling {
    private val lock = Mutex()
    private var connection: Signalling? = null

    /** A lone send or receive is a request of its own, so it gets the same reopen-and-retry as [exchange]. */
    override suspend fun send(message: RelayClientMessage) = exchange { send(message) }

    override suspend fun receive(): RelayServerMessage = exchange { receive() }

    override suspend fun <T> exchange(block: suspend Signalling.() -> T): T = lock.withLock { runWithRetry(block) }

    private suspend fun <T> runWithRetry(block: suspend Signalling.() -> T): T {
        val ladder = ReconnectLadder()
        var retried = false
        while (true) {
            val live = connectionFrom(ladder)
            try {
                return live.block()
            } catch (dropped: IOException) {
                connection = null
                if (retried) throw dropped
                retried = true
            }
        }
    }

    private suspend fun connectionFrom(ladder: ReconnectLadder): Signalling {
        connection?.let { return it }
        while (true) {
            try {
                return open().also { connection = it }
            } catch (unreachable: IOException) {
                val step = ladder.next() ?: throw unreachable
                pause(step)
            }
        }
    }
}
