package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionScreenStateTest {
    private val state = SessionScreenState()

    @Test
    fun openingAPanelPutsTheKeyboardAway() {
        state.toggleKeyboard()

        state.togglePanel(SessionPanel.CLIPBOARD)

        assertEquals(SessionPanel.CLIPBOARD, state.openPanel)
        assertFalse(state.keyboardShown)
    }

    @Test
    fun raisingTheKeyboardClosesThePanel() {
        state.togglePanel(SessionPanel.SHORTCUTS)

        state.toggleKeyboard()

        assertNull(state.openPanel)
        assertTrue(state.keyboardShown)
    }

    @Test
    fun theSamePanelToggledTwiceCloses() {
        state.togglePanel(SessionPanel.SETTINGS)
        state.togglePanel(SessionPanel.SETTINGS)

        assertNull(state.openPanel)
    }

    @Test
    fun anotherPanelReplacesTheOpenOne() {
        state.togglePanel(SessionPanel.SETTINGS)
        state.togglePanel(SessionPanel.SOURCES)

        assertEquals(SessionPanel.SOURCES, state.openPanel)
    }

    @Test
    fun backClosesAPanelThenTheKeyboardThenAsksToLeave() {
        state.showPanel(SessionPanel.SOURCES)
        assertEquals(BackStep.CLOSE_PANEL, state.backStep())

        state.closePanel()
        state.toggleKeyboard()
        assertEquals(BackStep.HIDE_KEYBOARD, state.backStep())

        state.hideKeyboard()
        assertEquals(BackStep.ASK_TO_LEAVE, state.backStep())
    }

    @Test
    fun immersiveModePutsAwayWhatWasOpen() {
        state.togglePanel(SessionPanel.SHORTCUTS)

        state.enterImmersive()

        assertTrue(state.immersive)
        assertNull(state.openPanel)
    }
}
