package pl.dmq.peering.feature.connect

import org.junit.Assert.assertEquals
import org.junit.Test

class HostListingTest {
    @Test
    fun connectedHostComesBeforeOnlineAndThenUnknown() {
        val listing = HostListing.of(
            nearby = emptyList(),
            paired = listOf(PairedHost("A", "Alpha"), PairedHost("B", "Bravo"), PairedHost("C", "Charlie")),
            online = setOf("C"),
            connected = "B",
        )

        assertEquals(listOf("B", "C", "A"), listing.paired.map { it.id })
        assertEquals(
            listOf(HostStatus.Connected, HostStatus.Online, HostStatus.Unknown),
            listing.paired.map { it.status },
        )
    }

    @Test
    fun namesSortIgnoringCaseAndUnnamedHostsSortLast() {
        val listing = HostListing.of(
            nearby = emptyList(),
            paired = listOf(
                PairedHost("1", null),
                PairedHost("2", "beta"),
                PairedHost("3", "Alpha"),
            ),
            online = setOf("1", "2", "3"),
            connected = null,
        )

        assertEquals(listOf("3", "2", "1"), listing.paired.map { it.id })
    }

    @Test
    fun equalNamesAndStatusesTieBreakOnId() {
        val listing = HostListing.of(
            nearby = emptyList(),
            paired = listOf(PairedHost("Z", "Same"), PairedHost("M", "Same")),
            online = emptySet(),
            connected = null,
        )

        assertEquals(listOf("M", "Z"), listing.paired.map { it.id })
    }

    @Test
    fun nearbyHostThatIsAlreadyPairedAppearsInBothLists() {
        val listing = HostListing.of(
            nearby = listOf(nearbyHost("A"), nearbyHost("N", name = "New Mac")),
            paired = listOf(PairedHost("A", null)),
            online = emptySet(),
            connected = null,
        )

        assertEquals(listOf("A"), listing.paired.map { it.id })
        assertEquals(listOf("A", "N"), listing.nearby.map { it.id }.sorted())
    }

    @Test
    fun pairedHostWithoutANameTakesTheNearbyName() {
        val listing = HostListing.of(
            nearby = listOf(nearbyHost("A", name = "Studio Mac")),
            paired = listOf(PairedHost("A", null)),
            online = emptySet(),
            connected = null,
        )

        assertEquals("Studio Mac", listing.paired.single().name)
    }

    @Test
    fun aNearbyHostIsOnlineAndTheConnectedOneIsConnected() {
        val listing = HostListing.of(
            nearby = listOf(nearbyHost("N1"), nearbyHost("N2")),
            paired = emptyList(),
            online = emptySet(),
            connected = "N2",
        )

        assertEquals(listOf(HostStatus.Connected, HostStatus.Online), listing.nearby.map { it.status })
    }

    @Test
    fun duplicateNearbyAnnouncementsShowOnce() {
        val listing = HostListing.of(
            nearby = listOf(nearbyHost("N1"), nearbyHost("N1", name = "Moved")),
            paired = emptyList(),
            online = emptySet(),
            connected = null,
        )

        assertEquals(1, listing.nearby.size)
    }
}
