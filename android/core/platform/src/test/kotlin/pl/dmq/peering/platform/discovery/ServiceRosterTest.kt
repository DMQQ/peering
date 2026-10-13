package pl.dmq.peering.platform.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.DiscoveryEvent
import pl.dmq.peering.session.ports.PeerAddress

class ServiceRosterTest {
    private fun host(id: String, port: Int) = DiscoveredHost(id, "Mac", 1, PeerAddress("192.168.1.5", port))

    @Test
    fun aNewServiceIsFound() {
        val roster = ServiceRoster()

        assertEquals(listOf<DiscoveryEvent>(DiscoveryEvent.Found(host("A", 51515))), roster.found("s", host("A", 51515)))
    }

    @Test
    fun aLostServiceDropsItsHost() {
        val roster = ServiceRoster()
        roster.found("s", host("A", 51599))

        assertEquals(listOf<DiscoveryEvent>(DiscoveryEvent.Lost("A")), roster.lost("s"))
    }

    @Test
    fun aHostWithTwoServicesIsLostOnlyWhenTheLastGoes() {
        val roster = ServiceRoster()
        roster.found("old", host("A", 51599))
        roster.found("new", host("A", 51515))

        assertTrue(roster.lost("old").isEmpty())
        assertEquals(listOf<DiscoveryEvent>(DiscoveryEvent.Lost("A")), roster.lost("new"))
    }

    @Test
    fun theMostRecentServiceWinsAndLosingItFallsBackToTheOlder() {
        val roster = ServiceRoster()
        roster.found("old", host("A", 51599))

        assertEquals(listOf<DiscoveryEvent>(DiscoveryEvent.Found(host("A", 51515))), roster.found("new", host("A", 51515)))
        assertEquals(listOf<DiscoveryEvent>(DiscoveryEvent.Found(host("A", 51599))), roster.lost("new"))
    }

    @Test
    fun anUnchangedHostIsNotAnnouncedAgain() {
        val roster = ServiceRoster()
        roster.found("s", host("A", 51515))

        assertTrue(roster.found("s", host("A", 51515)).isEmpty())
    }

    @Test
    fun aLostServiceThatWasNeverResolvedSaysNothing() {
        assertTrue(ServiceRoster().lost("unknown").isEmpty())
    }
}
