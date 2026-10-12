package pl.dmq.peering.feature.remote

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class StatusPillPresenterTest {
    private val scope = TestScope()
    private val pill = StatusPillPresenter(scope, autoCloseMillis = 2_500)

    private fun pass(millis: Long) {
        scope.advanceTimeBy(millis)
        scope.runCurrent()
    }

    @Test
    fun opensWhenTheSessionBecomesReady() {
        assertFalse(pill.expanded)
        pill.onReady(true)
        assertTrue(pill.expanded)
    }

    @Test
    fun closesItselfAfterTheDelay() {
        pill.onReady(true)
        pass(2_499)
        assertTrue(pill.expanded)
        pass(2)
        assertFalse(pill.expanded)
    }

    @Test
    fun staysClosedWhenAlreadyReadyAndTappedShut() {
        pill.onReady(true)
        pill.onTap()
        pill.onReady(true)
        assertFalse(pill.expanded)
    }

    @Test
    fun opensAgainWhenReadinessIsLostAndRegained() {
        pill.onReady(true)
        pill.collapse()
        pill.onReady(false)
        pill.onReady(true)
        assertTrue(pill.expanded)
    }

    @Test
    fun aTapOpensAndAnotherClosesIt() {
        pill.onTap()
        assertTrue(pill.expanded)
        pill.onTap()
        assertFalse(pill.expanded)
    }

    @Test
    fun aPillOpenedByTapStaysOpen() {
        pill.onTap()
        pass(10_000)
        assertTrue(pill.expanded)
    }

    @Test
    fun aTapDuringTheTimerCancelsItSoALaterOpenIsNotClosedByIt() {
        pill.onReady(true)
        pass(1_000)
        pill.onTap()
        assertFalse(pill.expanded)
        pill.onTap()
        pass(5_000)
        assertTrue(pill.expanded)
    }

    @Test
    fun touchingAControlKeepsTheAutoOpenedPillOpen() {
        pill.onReady(true)
        pill.onInteraction()
        pass(10_000)
        assertTrue(pill.expanded)
    }
}
