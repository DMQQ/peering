package pl.dmq.peering.feature.connect

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.R

class HostRouteTest {
    private val paired = listOf(PairedHost("A", "Alpha"), PairedHost("B", "Bravo"), PairedHost("C", "Charlie"))

    private fun listing() = HostListing.of(
        nearby = listOf(nearbyHost("A"), nearbyHost("N")),
        paired = paired,
        online = setOf("B"),
        connected = null,
    )

    @Test
    fun aPairedComputerSeenOnTheNetworkRoutesLocally() {
        assertEquals(HostRoute.Local, listing().paired.first { it.id == "A" }.route)
    }

    @Test
    fun aPairedComputerOnlyAnnouncedByTheRelayRoutesThroughIt() {
        assertEquals(HostRoute.Relay, listing().paired.first { it.id == "B" }.route)
    }

    @Test
    fun aPairedComputerNobodySawHasNoRoute() {
        assertEquals(HostRoute.None, listing().paired.first { it.id == "C" }.route)
    }

    @Test
    fun everyNearbyComputerRoutesLocally() {
        assertEquals(setOf(HostRoute.Local), listing().nearby.map { it.route }.toSet())
    }

    @Test
    fun theSupportingLineNamesTheRouteOfAPairedComputer() {
        val rows = listing().paired.associateBy { it.id }
        assertEquals(R.string.connect_status_local, rows.getValue("A").pairedDetailRes())
        assertEquals(R.string.connect_status_relay, rows.getValue("B").pairedDetailRes())
        assertEquals(R.string.connect_status_unknown, rows.getValue("C").pairedDetailRes())
    }

    @Test
    fun aConnectedComputerInvitesReturning() {
        val connected = HostRow("A", "Alpha", HostStatus.Connected, HostRoute.Local)
        assertEquals(R.string.connect_status_connected, connected.pairedDetailRes())
    }
}
