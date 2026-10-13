package pl.dmq.peering.feature.whatsnew

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.whatsnew.WhatsNewPolicy.Decision
import pl.dmq.peering.session.ports.KeyValueStore

class WhatsNewPolicyTest {
    @Test
    fun `a returning user is shown a release they have not seen`() {
        assertEquals(Decision.Show, WhatsNewPolicy.decide("r2", lastSeenRelease = "r1", hasFinishedFirstRun = true))
        assertEquals(Decision.Show, WhatsNewPolicy.decide("r1", lastSeenRelease = null, hasFinishedFirstRun = true))
    }

    @Test
    fun `a release already seen, or none, shows nothing`() {
        assertEquals(Decision.Nothing, WhatsNewPolicy.decide("r1", "r1", hasFinishedFirstRun = true))
        assertEquals(Decision.Nothing, WhatsNewPolicy.decide(null, "r1", hasFinishedFirstRun = true))
    }

    @Test
    fun `a first-time user is not told what is new but the release is recorded`() {
        assertEquals(Decision.RecordWithoutShowing, WhatsNewPolicy.decide("r1", null, hasFinishedFirstRun = false))
    }

    @Test
    fun `the seen release is kept in the store`() {
        val values = HashMap<String, String>()
        val store = WhatsNewStore(object : KeyValueStore {
            override fun read(key: String) = values[key]
            override fun write(key: String, value: String) { values[key] = value }
        })
        assertNull(store.lastSeen())

        store.record("2026-10-13")

        assertEquals("2026-10-13", store.lastSeen())
    }

    @Test
    fun `the current release has an id and items to announce`() {
        val release = WhatsNewRelease.current!!

        assertTrue(release.id.isNotBlank())
        assertTrue(release.items.isNotEmpty())
    }
}
