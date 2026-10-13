package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChromePolicyTest {
    private fun shown(
        immersive: Boolean = false,
        picture: PictureState = PictureState.LIVE,
        reconnecting: Boolean = false,
    ) = ChromePolicy.shown(immersive, picture, reconnecting)

    @Test
    fun `a live idle session keeps the chrome up`() {
        assertTrue(shown())
    }

    @Test
    fun `immersive mode hides the chrome on a live picture`() {
        assertFalse(shown(immersive = true))
    }

    @Test
    fun `immersive mode still shows the chrome while reconnecting`() {
        assertTrue(shown(immersive = true, reconnecting = true))
    }

    @Test
    fun `a picture that is not live shows the chrome even in immersive mode`() {
        listOf(PictureState.WAITING, PictureState.PAUSED, PictureState.STALLED, PictureState.FAILED)
            .forEach { assertTrue(it.name, shown(immersive = true, picture = it)) }
    }
}

class InputModesTest {
    @Test
    fun `the mode button swaps between observing and the control mode last used`() {
        assertEquals(InputMode.OBSERVE, InputModes.toggled(InputMode.TRACKPAD, lastControl = InputMode.TRACKPAD))
        assertEquals(InputMode.DIRECT, InputModes.toggled(InputMode.OBSERVE, lastControl = InputMode.DIRECT))
    }

    @Test
    fun `observing is never remembered as the control mode`() {
        assertEquals(InputMode.TRACKPAD, InputModes.controlModeAfter(InputMode.OBSERVE, previous = InputMode.TRACKPAD))
        assertEquals(InputMode.DIRECT, InputModes.controlModeAfter(InputMode.DIRECT, previous = InputMode.TRACKPAD))
    }
}
