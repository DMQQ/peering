package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase

class HubLifecycleTest {
    @Test
    fun surfaceReturningAfterAPictureWasShownAsksForAKeyframeOnce() {
        val returns = SurfaceReturn()
        returns.gone(hadPicture = true)
        assertTrue(returns.available())
        assertFalse(returns.available())
    }

    @Test
    fun aFirstSurfaceOrOneThatNeverShowedAPictureAsksForNothing() {
        val returns = SurfaceReturn()
        assertFalse(returns.available())
        returns.gone(hadPicture = false)
        assertFalse(returns.available())
    }

    @Test
    fun theHubStaysWhileItsSessionRunsOrReconnects() {
        assertFalse(hubShouldClose(isOpenedSession = true, phase = SessionPhase.Reconnecting(1)))
    }

    @Test
    fun theHubClosesWhenItsSessionIsReplacedGoneEndedOrFailed() {
        assertTrue(hubShouldClose(isOpenedSession = false, phase = null))
        assertTrue(hubShouldClose(isOpenedSession = true, phase = SessionPhase.Ended))
        assertTrue(hubShouldClose(isOpenedSession = true, phase = SessionPhase.Failed(SessionFailure.Quota, canRetry = false)))
    }
}
