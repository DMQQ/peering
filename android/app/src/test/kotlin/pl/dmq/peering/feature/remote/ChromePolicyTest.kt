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
    fun `a computer with no optional features gets keyboard, sources and more`() {
        assertEquals(
            listOf(ToolbarAction.KEYBOARD, ToolbarAction.SOURCES, ToolbarAction.MORE),
            presenter.actions(HubCapabilities.NONE),
        )
    }

    @Test
    fun `agents and files appear between sources and more when supported`() {
        assertEquals(
            listOf(ToolbarAction.KEYBOARD, ToolbarAction.SOURCES, ToolbarAction.AGENTS, ToolbarAction.FILES, ToolbarAction.MORE),
            presenter.actions(HubCapabilities(agentChat = true, fileBrowser = true)),
        )
        assertFalse(ToolbarAction.FILES in presenter.actions(HubCapabilities(agentChat = true, fileBrowser = false)))
        assertFalse(ToolbarAction.AGENTS in presenter.actions(HubCapabilities(agentChat = false, fileBrowser = true)))
    }

    @Test
    fun `every action maps to its effect`() {
        assertEquals(ToolbarEffect.ToggleKeyboard, presenter.effect(ToolbarAction.KEYBOARD))
        assertEquals(ToolbarEffect.OpenSources, presenter.effect(ToolbarAction.SOURCES))
        assertEquals(ToolbarEffect.OpenHub(HubEntry.AGENTS), presenter.effect(ToolbarAction.AGENTS))
        assertEquals(ToolbarEffect.OpenHub(HubEntry.FILES), presenter.effect(ToolbarAction.FILES))
        assertEquals(ToolbarEffect.OpenMore, presenter.effect(ToolbarAction.MORE))
    }

    @Test
    fun `the pointer toggle swaps between trackpad and touch`() {
        assertEquals(InputMode.DIRECT, presenter.otherMode(InputMode.TRACKPAD))
        assertEquals(InputMode.TRACKPAD, presenter.otherMode(InputMode.DIRECT))
    }
}

class RouteHealthTest {
    private fun health(picture: PictureState, reconnecting: Boolean = false) =
        RouteHealth.of(SessionOverlayState.of(null, null, null, picture, reconnecting, null))

    @Test
    fun `a live picture is good and a failed one is broken`() {
        assertEquals(RouteHealth.GOOD, health(PictureState.LIVE))
        assertEquals(RouteHealth.BROKEN, health(PictureState.FAILED))
    }

    @Test
    fun `a stall, a pause or a reconnect is degraded`() {
        assertEquals(RouteHealth.DEGRADED, health(PictureState.STALLED))
        assertEquals(RouteHealth.DEGRADED, health(PictureState.PAUSED))
        assertEquals(RouteHealth.DEGRADED, health(PictureState.LIVE, reconnecting = true))
    }

    @Test
    fun `waiting for the first picture is unknown`() {
        assertEquals(RouteHealth.UNKNOWN, health(PictureState.WAITING))
    }
}

class BackStepTest {
    @Test
    fun `back closes the keyboard first and then asks to leave`() {
        assertEquals(BackStep.HIDE_KEYBOARD, BackStep.of(keyboardShown = true))
        assertEquals(BackStep.ASK_TO_LEAVE, BackStep.of(keyboardShown = false))
    }
}
