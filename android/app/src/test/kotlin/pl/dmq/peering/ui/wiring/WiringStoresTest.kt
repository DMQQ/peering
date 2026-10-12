package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.agent.ComposerDraft
import pl.dmq.peering.session.agent.ComposerDrafts
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.PeerAddress

class WiringStoresTest {
    @Test
    fun aStoredQualityReadsBackAsTheSameChoice() {
        for (quality in StreamQuality.entries) {
            assertEquals(quality, storedStreamQuality(quality.stored()))
        }
    }

    @Test
    fun anUnknownOrMissingQualityReadsAsAuto() {
        assertEquals(StreamQuality.Auto, storedStreamQuality(null))
        assertEquals(StreamQuality.Auto, storedStreamQuality("Ultra"))
    }

    @Test
    fun draftsSurviveTheirOwnEncoding() {
        val drafts = ComposerDrafts(
            mapOf(
                "s1" to ComposerDraft(text = "fix the build", attachedPaths = listOf("/Users/me/a.txt")),
                "s2" to ComposerDraft(text = "", attachedPaths = listOf("/tmp/b")),
            ),
        )

        assertEquals(drafts, ComposerDraftCodec.decode(ComposerDraftCodec.encode(drafts)))
    }

    @Test
    fun aDamagedDraftStoreHoldsNothingRatherThanStoppingTheChats() {
        assertEquals(ComposerDrafts(), ComposerDraftCodec.decode("not json"))
        assertEquals(ComposerDrafts(), ComposerDraftCodec.decode("[1,2]"))
        assertEquals(ComposerDrafts(), ComposerDraftCodec.decode(null))
    }

    @Test
    fun aHostSeenAgainReplacesItsRowRatherThanAddingOne() {
        val first = DiscoveredHost("h1", "Studio", 20, PeerAddress("192.0.2.1", 7000))
        val moved = first.copy(address = PeerAddress("192.0.2.9", 7000))
        val other = DiscoveredHost("h2", "Office", 20, PeerAddress("192.0.2.2", 7000))

        val list = listOf(first, other).withFound(moved)

        assertEquals(listOf(other, moved), list)
    }

    @Test
    fun aPairedMacOnTheNetworkIsDialledDirectlyAndOtherwiseThroughTheRelay() {
        val address = PeerAddress("192.0.2.1", 7000)

        assertEquals(ConnectTarget.Lan(address, "h1"), pairedTarget("h1", address))
        assertEquals(ConnectTarget.Relay("h1"), pairedTarget("h1", null))
    }
}
