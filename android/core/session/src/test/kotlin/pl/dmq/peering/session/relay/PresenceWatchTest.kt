@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.relay

import java.io.IOException
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

class PresenceWatchTest {
    private val clock = FakeClock()

    private fun TestScope.watch(open: suspend () -> FakeSignalling, hosts: List<String>): PresenceWatch {
        val signalling = ResilientSignalling(open = open, pause = {})
        return PresenceWatch(RelayConnect(signalling, FakeIdentity(), clock), { hosts }, clock, backgroundScope)
    }

    @Test
    fun aHiddenScreenAsksTheRelayForNothing() = runTest {
        val relay = FakeSignalling()
        watch({ relay }, listOf("A"))

        runCurrent()

        assertEquals(emptyList<RelayClientMessage>(), relay.sent)
    }

    @Test
    fun aShownScreenAsksForEachPairedHostAndReportsTheOnlineOnes() = runTest {
        val relay = FakeSignalling()
        relay.reply(RelayServerMessage.HostPresence("A", online = true))
        relay.reply(RelayServerMessage.HostPresence("B", online = false))
        val watch = watch({ relay }, listOf("A", "B"))

        watch.setShown(true)
        runCurrent()

        assertEquals(setOf("A"), watch.onlineHostIds.value)
        assertEquals(
            listOf<RelayClientMessage>(RelayClientMessage.HostPresence("A"), RelayClientMessage.HostPresence("B")),
            relay.sent,
        )
    }

    @Test
    fun aFailedAskLeavesEveryHostUnknownRatherThanOffline() = runTest {
        val watch = watch({ throw IOException("relay unreachable") }, listOf("A"))

        watch.setShown(true)
        runCurrent()

        assertEquals(emptySet<String>(), watch.onlineHostIds.value)
    }

    @Test
    fun theRelayIsAskedAgainOnlyAfterTheIntervalEvenWhenTheScreenIsReopened() = runTest {
        val relay = FakeSignalling()
        relay.reply(RelayServerMessage.HostPresence("A", online = true))
        val watch = watch({ relay }, listOf("A"))
        watch.setShown(true)
        runCurrent()

        watch.setShown(false)
        watch.setShown(true)
        runCurrent()
        assertEquals(1, relay.sent.size)

        relay.reply(RelayServerMessage.HostPresence("A", online = true))
        clock.advance(15.0)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(2, relay.sent.size)
    }
}
