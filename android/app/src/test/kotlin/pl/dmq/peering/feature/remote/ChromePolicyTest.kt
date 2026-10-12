package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChromePolicyTest {
    private fun holds(
        keyboard: Boolean = false,
        overlay: Boolean = false,
        picture: PictureState = PictureState.LIVE,
        reconnecting: Boolean = false,
    ) = ChromePolicy.holdsChrome(keyboard, overlay, picture, reconnecting)

    @Test
    fun `a live idle session lets the chrome fold away`() {
        assertFalse(holds())
    }

    @Test
    fun `typing, an open sheet and a reconnect each keep the chrome up`() {
        assertTrue(holds(keyboard = true))
        assertTrue(holds(overlay = true))
        assertTrue(holds(reconnecting = true))
    }

    @Test
    fun `a picture that is not live keeps the chrome up so retry stays reachable`() {
        listOf(PictureState.WAITING, PictureState.PAUSED, PictureState.STALLED, PictureState.FAILED)
            .forEach { assertTrue(it.name, holds(picture = it)) }
    }
}

class ToolbarPresenterTest {
    private val presenter = ToolbarPresenter()

    @Test
    fun `fit is offered only while zoomed`() {
        assertFalse(ToolbarAction.FIT in presenter.actions(zoomed = false))
        assertTrue(ToolbarAction.FIT in presenter.actions(zoomed = true))
    }

    @Test
    fun `keyboard, pointer mode, sources, quality and menu are always offered`() {
        val actions = presenter.actions(zoomed = false)
        assertEquals(
            listOf(
                ToolbarAction.KEYBOARD,
                ToolbarAction.POINTER_MODE,
                ToolbarAction.SOURCES,
                ToolbarAction.QUALITY,
                ToolbarAction.MENU,
            ),
            actions,
        )
    }

    @Test
    fun `the pointer toggle swaps between trackpad and touch`() {
        assertEquals(InputMode.DIRECT, presenter.otherMode(InputMode.TRACKPAD))
        assertEquals(InputMode.TRACKPAD, presenter.otherMode(InputMode.DIRECT))
    }
}

class BackStepTest {
    @Test
    fun `back closes the keyboard first and then asks to leave`() {
        assertEquals(BackStep.HIDE_KEYBOARD, BackStep.of(keyboardShown = true))
        assertEquals(BackStep.ASK_TO_LEAVE, BackStep.of(keyboardShown = false))
    }
}
