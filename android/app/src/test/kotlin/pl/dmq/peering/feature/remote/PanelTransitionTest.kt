package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PanelTransitionTest {
    @Test
    fun tappingTheOpenPanelsButtonCloses() {
        assertNull(panelAfterTap(SessionPanel.SETTINGS, SessionPanel.SETTINGS))
    }

    @Test
    fun tappingAnotherButtonSwitchesDirectlyWithoutPassingThroughClosed() {
        assertEquals(SessionPanel.CLIPBOARD, panelAfterTap(SessionPanel.SETTINGS, SessionPanel.CLIPBOARD))
    }

    @Test
    fun tappingWithNothingOpenOpens() {
        assertEquals(SessionPanel.SOURCES, panelAfterTap(null, SessionPanel.SOURCES))
    }

    @Test
    fun theLeavingSurfaceKeepsTheLastPanel() {
        val memory = PanelMemory()
        assertNull(memory.shown(null))
        assertEquals(SessionPanel.SOURCES, memory.shown(SessionPanel.SOURCES))
        assertEquals(SessionPanel.SOURCES, memory.shown(null))
        assertEquals(SessionPanel.SETTINGS, memory.shown(SessionPanel.SETTINGS))
    }
}
