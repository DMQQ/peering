package pl.dmq.peering.session.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SoundOutputTest {
    private val playing = SoundConditions(muted = false, appInForeground = true, focus = FocusState.HELD, routeLost = false)

    @Test
    fun soundPlaysInFullWhenEverythingAllowsIt() {
        assertEquals(SoundOutput.FULL, playing.output)
    }

    @Test
    fun muteSilencesItAndStopsAskingForFocus() {
        val muted = playing.copy(muted = true)
        assertEquals(SoundOutput.SILENT, muted.output)
        assertFalse(muted.wantsFocus)
    }

    @Test
    fun leavingTheAppSilencesIt() {
        assertEquals(SoundOutput.SILENT, playing.copy(appInForeground = false).output)
    }

    @Test
    fun aLostOutputRouteSilencesItUntilCleared() {
        assertEquals(SoundOutput.SILENT, playing.copy(routeLost = true).output)
    }

    @Test
    fun anotherAppDuckingUsPlaysQuietly() {
        assertEquals(SoundOutput.DUCKED, playing.copy(focus = FocusState.DUCKED).output)
    }

    @Test
    fun withoutFocusItStaysSilentButStillAsksForIt() {
        for (focus in listOf(FocusState.NONE, FocusState.LOST)) {
            val unfocused = playing.copy(focus = focus)
            assertEquals(SoundOutput.SILENT, unfocused.output)
            assertTrue(unfocused.wantsFocus)
        }
    }
}
