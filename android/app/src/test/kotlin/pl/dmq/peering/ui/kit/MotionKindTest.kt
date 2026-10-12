package pl.dmq.peering.ui.kit

import org.junit.Assert.assertEquals
import org.junit.Test

class MotionKindTest {
    @Test
    fun goingDeeperSlidesForwardAndBackReverses() {
        assertEquals(MotionKind.FORWARD, depthMotion(0, 1))
        assertEquals(MotionKind.BACKWARD, depthMotion(2, 1))
    }

    @Test
    fun peersAtTheSameDepthCrossfade() {
        assertEquals(MotionKind.CROSSFADE, depthMotion(1, 1))
    }

    @Test
    fun liveScreenOnEitherSideOnlyFades() {
        assertEquals(MotionKind.FADE, stageMotion(0, false, 3, true))
        assertEquals(MotionKind.FADE, stageMotion(3, true, 0, false))
    }

    @Test
    fun stagesWithoutVideoFollowDepth() {
        assertEquals(MotionKind.FORWARD, stageMotion(0, false, 1, false))
        assertEquals(MotionKind.BACKWARD, stageMotion(2, false, 1, false))
    }

    @Test
    fun modalRisesOnOpenSinksOnCloseAndCrossfadesBetweenModals() {
        assertEquals(MotionKind.MODAL_UP, modalMotion(fromModal = false, toModal = true))
        assertEquals(MotionKind.MODAL_DOWN, modalMotion(fromModal = true, toModal = false))
        assertEquals(MotionKind.CROSSFADE, modalMotion(fromModal = true, toModal = true))
    }

    @Test
    fun aPageOverLiveVideoSlidesInFromTheRightAndBackOut() {
        assertEquals(MotionKind.PUSH_IN, pushMotion(fromPage = false, toPage = true))
        assertEquals(MotionKind.PUSH_OUT, pushMotion(fromPage = true, toPage = false))
        assertEquals(MotionKind.CROSSFADE, pushMotion(fromPage = false, toPage = false))
    }
}
