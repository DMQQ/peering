package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class HubPresenterTest {
    private val hub = HubPresenter()

    @Test
    fun `a Mac with no optional features offers sources, quality and disconnect`() {
        assertEquals(
            listOf(HubEntry.SOURCES, HubEntry.QUALITY, HubEntry.DISCONNECT),
            hub.entries(HubCapabilities.NONE),
        )
    }

    @Test
    fun `agents appear only when the Mac supports agent chat`() {
        val entries = hub.entries(HubCapabilities(agentChat = true, fileBrowser = false))

        assertEquals(listOf(HubEntry.SOURCES, HubEntry.AGENTS, HubEntry.QUALITY, HubEntry.DISCONNECT), entries)
    }

    @Test
    fun `files appear only when the Mac supports the file browser`() {
        val entries = hub.entries(HubCapabilities(agentChat = false, fileBrowser = true))

        assertEquals(listOf(HubEntry.SOURCES, HubEntry.FILES, HubEntry.QUALITY, HubEntry.DISCONNECT), entries)
    }

    @Test
    fun `the more sheet lists quality and disconnect with disconnect last`() {
        assertEquals(listOf(HubEntry.QUALITY, HubEntry.DISCONNECT), hub.moreEntries())
    }

    @Test
    fun `a Mac with everything lists every entry in order with disconnect last`() {
        val entries = hub.entries(HubCapabilities(agentChat = true, fileBrowser = true))

        assertEquals(
            listOf(
                HubEntry.SOURCES,
                HubEntry.AGENTS,
                HubEntry.FILES,
                HubEntry.QUALITY,
                HubEntry.DISCONNECT,
            ),
            entries,
        )
    }
}
