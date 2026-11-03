package pl.dmq.peering.ui.kit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MotionSpecTest {
    @Test
    fun durationsRiseFromFastToEmphasizedAndExitsAreShortest() {
        assertTrue(Motion.EXIT_MS < Motion.FAST_MS)
        assertTrue(Motion.FAST_MS < Motion.STANDARD_MS)
        assertTrue(Motion.STANDARD_MS < Motion.EMPHASIZED_MS)
    }

    @Test
    fun entrancesRiseByNoMoreThanEightDp() {
        assertTrue(Motion.rise.value <= 8f)
    }

    @Test
    fun sharedAxisFadesInOnlyAfterTheOldPageIsGone() {
        assertEquals(30f, Motion.axisDistance.value, 0f)
        assertTrue(Motion.EXIT_MS + Motion.AXIS_FADE_IN_MS <= Motion.AXIS_MS)
    }

    @Test
    fun loadingStatesWaitBeforeAppearing() {
        assertEquals(150L, Motion.LOADING_DELAY_MS)
    }
}
