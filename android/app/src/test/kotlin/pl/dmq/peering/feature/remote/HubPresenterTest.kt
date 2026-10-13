package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class HubPresenterTest {
    private val hub = HubPresenter()

    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    private val everything = listOf(HubTab.AGENTS, HubTab.TERMINALS, HubTab.FILES)

    @Test
    fun aComputerWithNoOptionalFeaturesOffersNoTabs() {
        assertEquals(emptyList<HubTab>(), hub.offeredTabs(HubCapabilities.NONE))
    }

    @Test
    fun agentsAppearOnlyWhenTheComputerSupportsAgentChat() {
        assertEquals(listOf(HubTab.AGENTS), hub.offeredTabs(HubCapabilities(agentChat = true, fileBrowser = false)))
    }

    @Test
    fun filesAppearOnlyWhenTheComputerSupportsTheFileBrowser() {
        assertEquals(listOf(HubTab.FILES), hub.offeredTabs(HubCapabilities(agentChat = false, fileBrowser = true)))
    }

    @Test
    fun aComputerWithEverythingListsAgentsTerminalsFiles() {
        assertEquals(everything, hub.offeredTabs(HubCapabilities(agentChat = true, fileBrowser = true, terminal = true)))
    }

    @Test
    fun theHubOpensOnTheFirstTabWhenNothingWasUsedBefore() {
        assertEquals(HubTab.AGENTS, HubTabsPresenter(everything, MemoryStore()).selected)
    }

    @Test
    fun theHubOpensOnTheTabUsedLast() {
        val store = MemoryStore()
        HubTabsPresenter(everything, store).select(HubTab.FILES)
        assertEquals(HubTab.FILES, HubTabsPresenter(everything, store).selected)
    }

    @Test
    fun aRememberedTabTheComputerNoLongerOffersFallsBackToTheFirst() {
        val store = MemoryStore()
        HubTabsPresenter(everything, store).select(HubTab.FILES)
        assertEquals(HubTab.AGENTS, HubTabsPresenter(listOf(HubTab.AGENTS, HubTab.TERMINALS), store).selected)
    }

    @Test
    fun switchingTabsChangesTheSelectionAndIgnoresTabsNotOffered() {
        val presenter = HubTabsPresenter(listOf(HubTab.AGENTS, HubTab.TERMINALS), MemoryStore())
        presenter.select(HubTab.TERMINALS)
        assertEquals(HubTab.TERMINALS, presenter.selected)
        presenter.select(HubTab.FILES)
        assertEquals(HubTab.TERMINALS, presenter.selected)
    }

    @Test
    fun noTabsMeansNothingSelected() {
        assertNull(HubTabsPresenter(emptyList(), MemoryStore()).selected)
    }
}
