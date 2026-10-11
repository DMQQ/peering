package pl.dmq.peering.session.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress

class DirectPathProberTest {
    private val prober = DirectPathProber()
    private val peer = PeerAddress("203.0.113.7", 6000)

    /** Ticks on a 50 ms grid, so every step time (a multiple of 0.25 s) is one of the ticks. */
    private fun ticksUntil(endSeconds: Int, actionsAt: (Double, List<ProbeAction>) -> Unit) {
        for (index in 0..endSeconds * 20) {
            val now = index / 20.0
            actionsAt(now, prober.tick(now))
        }
    }

    @Test
    fun theFirstTickAsksTheRelayAndNothingIsProbedUntilAnAddressIsKnown() {
        assertEquals(listOf<ProbeAction>(ProbeAction.AskRelay), prober.tick(0.0))

        assertTrue(prober.tick(0.25).none { it is ProbeAction.SendProbe })
    }

    @Test
    fun aKnownAddressIsReportedAndProbedOnTheNextStep() {
        prober.tick(0.0)
        prober.onPeerAddress(peer.host, peer.port)

        assertEquals(
            listOf(ProbeAction.Report(DirectPathState.Probing(peer)), ProbeAction.SendProbe(peer)),
            prober.tick(0.25),
        )
    }

    @Test
    fun probesRunEveryQuarterSecondForTwelveAttemptsThenEveryFiveSeconds() {
        prober.onAuthenticatedDatagram(peer)
        val probeTimes = mutableListOf<Double>()

        ticksUntil(endSeconds = 10) { now, actions ->
            if (actions.any { it is ProbeAction.SendProbe }) probeTimes += now
        }

        val fastSteps = (0..12).map { it * 0.25 }
        assertEquals(fastSteps + 8.0, probeTimes)
    }

    @Test
    fun theRelayIsAskedAgainEveryTwelveAttempts() {
        val askTimes = mutableListOf<Double>()

        ticksUntil(endSeconds = 70) { now, actions ->
            if (actions.contains(ProbeAction.AskRelay)) askTimes += now
        }

        assertEquals(listOf(0.0, 3.0, 63.0), askTimes)
    }

    @Test
    fun anAuthenticatedDatagramOpensThePathAndBecomesTheDestination() {
        prober.onPeerAddress(peer.host, peer.port)
        prober.tick(0.0)
        val source = PeerAddress("198.51.100.4", 5150)

        prober.onAuthenticatedDatagram(source)

        assertEquals(DirectPathState.Open(source), prober.state)
        val expected = listOf<ProbeAction>(ProbeAction.Report(DirectPathState.Open(source)), ProbeAction.SendProbe(source))
        assertEquals(expected, prober.tick(0.25))
    }

    @Test
    fun anOpenPathIsNotDowngradedByALaterLookup() {
        val source = PeerAddress("198.51.100.4", 5150)
        prober.onAuthenticatedDatagram(source)
        prober.tick(0.0)

        prober.onPeerAddressUnknown()
        prober.onPeerAddress("192.0.2.9", 5200)
        val reports = prober.tick(0.25).filterIsInstance<ProbeAction.Report>()

        assertTrue(reports.isEmpty())
        assertEquals(DirectPathState.Open(source), prober.state)
    }

    @Test
    fun aMissingAddressIsReportedAsNoAddress() {
        prober.tick(0.0)
        prober.onPeerAddressUnknown()

        val actions = prober.tick(0.25)

        assertEquals(listOf<ProbeAction>(ProbeAction.Report(DirectPathState.NoAddress)), actions)
    }

    @Test
    fun anUnusableAddressIsReportedAndNeverProbed() {
        prober.onPeerAddress("", 6000)
        val first = prober.tick(0.0)
        prober.onPeerAddress("203.0.113.7", 0)
        val second = prober.tick(0.25)

        assertEquals(listOf<ProbeAction>(ProbeAction.Report(DirectPathState.AddressUnusable(PeerAddress("", 6000)))), first)
        assertEquals(
            listOf<ProbeAction>(ProbeAction.Report(DirectPathState.AddressUnusable(PeerAddress("203.0.113.7", 0)))),
            second,
        )
    }

    @Test
    fun aStateIsReportedOnlyWhenItChanges() {
        prober.onPeerAddress(peer.host, peer.port)
        prober.tick(0.0)

        prober.onPeerAddress(peer.host, peer.port)
        val actions = prober.tick(0.25)

        assertTrue(actions.none { it is ProbeAction.Report })
    }

    @Test
    fun anAuthenticatedSourceReplacesTheLookedUpDestination() {
        prober.onPeerAddress(peer.host, peer.port)
        prober.tick(0.0)
        val source = PeerAddress("198.51.100.4", 5150)

        prober.onAuthenticatedDatagram(source)

        assertEquals(source, prober.destination)
    }
}
