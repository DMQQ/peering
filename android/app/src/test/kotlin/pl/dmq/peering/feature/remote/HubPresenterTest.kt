package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class HubPresenterTest {
    private val hub = HubPresenter()

    @Test
    fun `a computer with no optional features offers nothing behind the terminal button`() {
        assertEquals(emptyList<HubEntry>(), hub.terminalEntries(HubCapabilities.NONE))
    }

    @Test
    fun `agents appear only when the computer supports agent chat`() {
        assertEquals(listOf(HubEntry.AGENTS), hub.terminalEntries(HubCapabilities(agentChat = true, fileBrowser = false)))
    }

    @Test
    fun `files appear only when the computer supports the file browser`() {
        assertEquals(listOf(HubEntry.FILES), hub.terminalEntries(HubCapabilities(agentChat = false, fileBrowser = true)))
    }

    @Test
    fun `a computer with everything lists the terminal first`() {
        assertEquals(
            listOf(HubEntry.TERMINAL, HubEntry.AGENTS, HubEntry.FILES),
            hub.terminalEntries(HubCapabilities(agentChat = true, fileBrowser = true, terminal = true)),
        )
    }
}
