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
    fun aNearbyUnpairedComputerRoutesLocally() {
        assertEquals(HostRoute.Local, listing().nearby.single().route)
    }

    @Test
    fun theSupportingLineNamesTheRouteOfAPairedComputer() {
        val rows = listing().paired.associateBy { it.id }
        assertEquals(R.string.connect_status_local, rows.getValue("A").supportingRes(paired = true))
        assertEquals(R.string.connect_status_relay, rows.getValue("B").supportingRes(paired = true))
        assertEquals(R.string.connect_status_unknown, rows.getValue("C").supportingRes(paired = true))
    }

    @Test
    fun aNearbyComputerInvitesPairingAndAConnectedOneInvitesReturning() {
        assertEquals(R.string.connect_nearby_tap_to_pair, listing().nearby.single().supportingRes(paired = false))
        val connected = HostRow("A", "Alpha", HostStatus.Connected, HostRoute.Local)
        assertEquals(R.string.connect_status_connected, connected.supportingRes(paired = true))
    }
}
