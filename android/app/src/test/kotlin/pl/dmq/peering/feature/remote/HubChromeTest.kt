package pl.dmq.peering.feature.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HubChromeTest {
    @Test
    fun everyTabStartsOnItsListPage() {
        val chrome = HubChrome()
        HubTab.entries.forEach { assertTrue(chrome.atRoot(it)) }
        assertTrue(chrome.showsSwitcher(HubTab.AGENTS))
    }

    @Test
    fun aDetailPageHidesTheSwitcherOfItsOwnTabOnly() {
        val chrome = HubChrome()
        chrome.setAtRoot(HubTab.TERMINALS, false)
        assertFalse(chrome.showsSwitcher(HubTab.TERMINALS))
        assertTrue(chrome.showsSwitcher(HubTab.AGENTS))
    }

    @Test
    fun goingBackToTheListBringsTheSwitcherBack() {
        val chrome = HubChrome()
        chrome.setAtRoot(HubTab.FILES, false)
        chrome.setAtRoot(HubTab.FILES, true)
        assertTrue(chrome.showsSwitcher(HubTab.FILES))
    }

    @Test
    fun aTabLeftOnADetailPageDoesNotHideTheNextTabsSwitcher() {
        val chrome = HubChrome()
        chrome.setAtRoot(HubTab.AGENTS, false)
        assertTrue(chrome.showsSwitcher(HubTab.FILES))
        chrome.setAtRoot(HubTab.AGENTS, true)
        assertTrue(chrome.atRoot(HubTab.AGENTS))
    }

    @Test
    fun withNoTabSelectedTheSwitcherStays() {
        assertTrue(HubChrome().showsSwitcher(null))
    }
}
