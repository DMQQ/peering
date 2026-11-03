package pl.dmq.peering.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.sessionmode.SessionMode
import pl.dmq.peering.feature.sessionmode.SessionModeMemory
import pl.dmq.peering.session.ports.KeyValueStore

class SessionModesTest {
    private class MapStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    private class FakePicture(var accepts: Boolean = true) : PictureSwitch {
        override var pictureOn = true
        val sent = mutableListOf<Boolean>()

        override fun setPictureEnabled(enabled: Boolean): Boolean {
            sent += enabled
            if (accepts) pictureOn = enabled
            return accepts
        }
    }

    private val store = MapStore()
    private val picture = FakePicture()
    private var route = SessionRoute.REMOTE
    private var hubOpened = 0
    private var savedMode: SessionMode? = null
    private val modes = SessionModes(
        hostId = "mac",
        memory = SessionModeMemory(store),
        picture = picture,
        workspaceOffered = { true },
        navigation = SessionNavigation(route = { route }, show = { route = it }, openHub = { hubOpened += 1 }),
        mode = null,
        setMode = { savedMode = it },
    )

    @Test
    fun choosingTheDockPausesThePictureAndShowsTheDock() {
        modes.choose(SessionMode.REMOTE)
        assertEquals(listOf(false), picture.sent)
        assertEquals(SessionRoute.DOCK, route)
    }

    @Test
    fun backFromThePickerOverTheHubReturnsToTheScreenWithThePictureOn() {
        modes.choose(SessionMode.WORKSPACE)
        assertEquals(1, hubOpened)
        modes.back()
        assertEquals(SessionRoute.REMOTE, route)
        assertEquals(SessionMode.SCREEN, modes.mode)
        assertEquals(SessionMode.SCREEN, savedMode)
        assertTrue(picture.pictureOn)
    }

    @Test
    fun backFromThePickerOverTheDockReturnsToTheDock() {
        modes.choose(SessionMode.REMOTE)
        modes.ask()
        modes.back()
        assertEquals(SessionRoute.DOCK, route)
    }

    @Test
    fun aModeComparesAgainstTheControllersPictureNotThePreviousMode() {
        picture.pictureOn = false
        modes.choose(SessionMode.SCREEN)
        assertEquals(listOf(true), picture.sent)
    }

    @Test
    fun aLaterLinkLeavesThePauseToTheControllerSoItIsNotSentTwice() {
        modes.choose(SessionMode.REMOTE)
        picture.pictureOn = true
        modes.ready(asksEveryTime = false, firstTime = false)
        assertEquals(listOf(false), picture.sent)
    }

    @Test
    fun theFirstReadyOpensTheRememberedMode() {
        store.values["session_mode.mac"] = "remote"
        modes.ready(asksEveryTime = false, firstTime = true)
        assertEquals(SessionRoute.DOCK, route)
    }
}
