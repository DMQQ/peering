package pl.dmq.peering.feature.agents

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class HubGuidePresenterTest {
    private class MapStore : KeyValueStore {
        val values = mutableMapOf<String, String>()

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    @Test
    fun showsOnFirstRun() {
        val guide = HubGuidePresenter(MapStore())
        assertTrue(guide.visible)
        assertFalse(guide.offersHelp)
    }

    @Test
    fun staysDismissedAcrossLaunches() {
        val store = MapStore()
        HubGuidePresenter(store).dismiss()
        val next = HubGuidePresenter(store)
        assertFalse(next.visible)
        assertTrue(next.offersHelp)
    }

    @Test
    fun reopeningDoesNotForgetThatItWasSeen() {
        val store = MapStore()
        val guide = HubGuidePresenter(store)
        guide.dismiss()
        guide.reopen()
        assertTrue(guide.visible)
        assertFalse(HubGuidePresenter(store).visible)
    }
}
