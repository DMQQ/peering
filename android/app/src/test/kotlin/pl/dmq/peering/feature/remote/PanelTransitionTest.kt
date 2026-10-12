package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class PanelTransitionTest {
    @Test
    fun openingFromNothingRises() {
        assertEquals(PanelTransition.RISE, panelTransition(null, SessionPanel.CLIPBOARD))
    }

    @Test
    fun closingFalls() {
        assertEquals(PanelTransition.FALL, panelTransition(SessionPanel.SETTINGS, null))
    }

    @Test
    fun switchingBetweenPanelsOnlyFades() {
        assertEquals(PanelTransition.CROSSFADE, panelTransition(SessionPanel.SOURCES, SessionPanel.SETTINGS))
    }

    @Test
    fun staysPutWhenNothingChanges() {
        assertEquals(PanelTransition.NONE, panelTransition(null, null))
        assertEquals(PanelTransition.NONE, panelTransition(SessionPanel.SOURCES, SessionPanel.SOURCES))
    }
}
