@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.PeerAddress
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class RouteRaceTest {
    private val mac = ScriptedMac()

    private fun route(path: SessionRecord.Path) =
        OpenedRoute(mac.newConnection(), path, PeerAddress("192.0.2.1", 1), ByteArray(0), datagrams = null)

    private fun timedOut() = ConnectFailure(SessionFailure.ConnectionFailed(ConnectFailureKind.Timeout, "no answer"))

    @Test
    fun aRelayWithAHeadStartDoesNotStartWhenTheLocalDialAnswersInTime() = runTest {
        var relayStarted = false
        val lan = route(SessionRecord.Path.LAN)

        val won = RouteRace(
            listOf(
                RouteRace.Attempt(0.milliseconds) { delay(100); lan },
                RouteRace.Attempt(300.milliseconds) { relayStarted = true; route(SessionRecord.Path.RELAY) },
            ),
        ).run()

        assertSame(lan, won)
        assertTrue(!relayStarted)
    }

    @Test
    fun aSlowLocalDialIsOvertakenByTheRelayAfterTheHeadStartAndIsClosed() = runTest {
        val relay = route(SessionRecord.Path.RELAY)

        val won = RouteRace(
            listOf(
                RouteRace.Attempt(0.milliseconds) { delay(10.seconds); route(SessionRecord.Path.LAN) },
                RouteRace.Attempt(300.milliseconds) { delay(200); relay },
            ),
        ).run()

        assertSame(relay, won)
        assertEquals(500, currentTime)
    }

    @Test
    fun aFailedLocalDialStartsTheRelayAtOnceWhateverItsHeadStart() = runTest {
        val relay = route(SessionRecord.Path.RELAY)

        val won = RouteRace(
            listOf(
                RouteRace.Attempt(0.milliseconds) { delay(50); throw timedOut() },
                RouteRace.Attempt(null) { relay },
            ),
        ).run()

        assertSame(relay, won)
        assertEquals(50, currentTime)
    }

    @Test
    fun whenEveryAttemptFailsTheLastFailureIsThrown() = runTest {
        val last = ConnectFailure(SessionFailure.HostOffline("h"))

        val thrown = runCatching {
            RouteRace(
                listOf(
                    RouteRace.Attempt(0.milliseconds) { throw timedOut() },
                    RouteRace.Attempt(null) { throw last },
                ),
            ).run()
        }.exceptionOrNull()

        assertSame(last, thrown)
    }
}
