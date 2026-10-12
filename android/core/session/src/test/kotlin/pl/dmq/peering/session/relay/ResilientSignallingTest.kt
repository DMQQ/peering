package pl.dmq.peering.session.relay

import java.io.IOException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

class ResilientSignallingTest {
    private val pauses = mutableListOf<Duration>()
    private val script = ArrayDeque<suspend () -> Signalling>()
    private var openings = 0

    private fun signalling(vararg replies: RelayServerMessage) = ScriptedConnection(replies.toList())

    private fun resilient() = ResilientSignalling(
        open = {
            openings++
            script.removeFirst()()
        },
        pause = { pauses += it },
    )

    @Test
    fun aSuccessfulRequestOnALiveConnectionRunsOnceAndReusesTheConnection() = runTest {
        script += { signalling(pong, pong) }
        val relay = resilient()

        relay.exchange { send(ping) }
        val second = relay.exchange { receive() }

        assertEquals(pong, second)
        assertEquals(1, openings)
        assertEquals(emptyList<Duration>(), pauses)
    }

    @Test
    fun aDroppedConnectionIsReplacedAndTheRequestRunsAgain() = runTest {
        val dropped = signalling()
        val fresh = signalling(pong)
        script += { dropped }
        script += { fresh }
        val relay = resilient()

        val reply = relay.exchange {
            send(ping)
            receive()
        }

        assertEquals(pong, reply)
        assertEquals(2, openings)
        assertEquals(listOf<RelayClientMessage>(ping), fresh.sent)
    }

    @Test
    fun aRequestThatDropsAgainOnTheNewConnectionIsThrownAfterOneRetry() = runTest {
        script += { signalling() }
        script += { signalling() }
        val relay = resilient()

        val failure = runCatching { relay.exchange { receive() } }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertEquals(2, openings)
    }

    @Test
    fun aFailedOpenWaitsOnTheReconnectLadderThenConnects() = runTest {
        script += { throw IOException("relay unreachable") }
        script += { signalling(pong) }
        val relay = resilient()

        assertEquals(pong, relay.exchange { receive() })
        assertEquals(listOf(500.milliseconds), pauses)
    }

    @Test
    fun anOpenThatFailsThroughEveryLadderStepIsThrown() = runTest {
        repeat(6) { script += { throw IOException("relay unreachable") } }
        val relay = resilient()

        val failure = runCatching { relay.exchange { receive() } }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertEquals(6, openings)
        assertEquals(listOf(500.milliseconds, 1.seconds, 2.seconds, 5.seconds, 5.seconds), pauses)
    }

    @Test
    fun aRefusalFromTheRelayIsNotTreatedAsADropAndKeepsTheConnection() = runTest {
        script += { signalling(refusal, pong) }
        val relay = resilient()

        val refused = runCatching {
            relay.exchange<Unit> {
                receive()
                throw IllegalStateException("refused")
            }
        }.exceptionOrNull()

        assertTrue(refused is IllegalStateException)
        assertEquals(pong, relay.exchange { receive() })
        assertEquals(1, openings)
    }

    @Test
    fun aConnectionThatNeverAnswersTimesOutAsAnIOExceptionAndIsDropped() = runTest {
        val silent = HangingConnection()
        script += { silent }
        script += { silent }
        val relay = resilient()

        val failure = runCatching { relay.exchange { receive() } }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertEquals(2, silent.dropped)
        assertEquals(10_000L * 2, testScheduler.currentTime)
    }

    @Test
    fun aRequestThatIsNotIdempotentIsNotResentAfterItWasSent() = runTest {
        script += { signalling() }
        script += { signalling(pong) }
        val relay = resilient()

        val failure = runCatching {
            relay.exchange(idempotent = false) {
                send(ping)
                receive()
            }
        }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertEquals(1, openings)
    }

    @Test
    fun aRequestThatIsNotIdempotentIsRetriedWhenTheConnectionFailedBeforeTheSend() = runTest {
        script += { DeadOnSend }
        val fresh = signalling(pong)
        script += { fresh }
        val relay = resilient()

        val reply = relay.exchange(idempotent = false) {
            send(ping)
            receive()
        }

        assertEquals(pong, reply)
        assertEquals(listOf<RelayClientMessage>(ping), fresh.sent)
    }

    @Test
    fun dropAbandonsTheConnectionSoTheNextRequestOpensANewOne() = runTest {
        val first = signalling(pong)
        script += { first }
        script += { signalling(pong) }
        val relay = resilient()
        relay.exchange { receive() }

        relay.drop()
        relay.exchange { receive() }

        assertEquals(1, first.dropped)
        assertEquals(2, openings)
    }

    private object DeadOnSend : Signalling {
        override suspend fun send(message: RelayClientMessage) = throw IOException("relay connection is closed")

        override suspend fun receive(): RelayServerMessage = throw IOException("relay connection is closed")
    }

    private class HangingConnection : Signalling {
        var dropped = 0

        override suspend fun send(message: RelayClientMessage) = Unit

        override suspend fun receive(): RelayServerMessage = awaitCancellation()

        override fun drop() {
            dropped++
        }
    }

    private class ScriptedConnection(private val replies: List<RelayServerMessage>) : Signalling {
        val sent = mutableListOf<RelayClientMessage>()
        var dropped = 0
        private var next = 0

        override fun drop() {
            dropped++
        }

        override suspend fun send(message: RelayClientMessage) {
            sent += message
        }

        override suspend fun receive(): RelayServerMessage {
            if (next >= replies.size) throw IOException("relay connection closed")
            return replies[next++]
        }
    }

    private companion object {
        val ping = RelayClientMessage.HostPresence("A")
        val pong = RelayServerMessage.HostPresence("A", online = true)
        val refusal = RelayServerMessage.HostPresence("B", online = false)
    }
}
