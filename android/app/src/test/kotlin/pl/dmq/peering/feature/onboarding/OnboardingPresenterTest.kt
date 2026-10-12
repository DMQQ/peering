package pl.dmq.peering.feature.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingPresenterTest {
    @Test
    fun startsOnTheWhatIsPeeringStepWithNothingCompleted() {
        val ui = OnboardingPresenter(FakeFirstRunStore()).ui.value
        assertEquals(OnboardingStep.WHAT_IS_PEERING, ui.step)
        assertEquals(1, ui.stepNumber)
        assertEquals(3, ui.stepCount)
        assertFalse(ui.canGoBack)
        assertFalse(ui.completed)
    }

    @Test
    fun nextMovesThroughTheStepsInOrder() {
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        presenter.next()
        assertEquals(OnboardingStep.INSTALL_HOST, presenter.ui.value.step)
        presenter.next()
        assertEquals(OnboardingStep.SCAN_CODE, presenter.ui.value.step)
        assertTrue(presenter.ui.value.isLastStep)
    }

    @Test
    fun backReturnsOneStepAndNotBeforeTheFirst() {
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        presenter.back()
        assertEquals(OnboardingStep.WHAT_IS_PEERING, presenter.ui.value.step)
        presenter.next()
        presenter.back()
        assertEquals(OnboardingStep.WHAT_IS_PEERING, presenter.ui.value.step)
    }

    @Test
    fun finishingTheLastStepSetsThePersistenceFlagOnce() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        presenter.next()
        presenter.next()
        presenter.next()
        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
        presenter.next()
        presenter.skip()
        assertEquals(1, store.marks)
    }

    @Test
    fun skippingAtAnyStepCompletesTheFirstRun() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        presenter.skip()
        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
    }

    @Test
    fun aFirstRunThatWasFinishedBeforeStaysCompleted() {
        val presenter = OnboardingPresenter(FakeFirstRunStore(complete = true))
        assertTrue(presenter.ui.value.completed)
        presenter.next()
        assertEquals(OnboardingStep.WHAT_IS_PEERING, presenter.ui.value.step)
    }

    @Test
    fun theStepsKnowTheirNeighbours() {
        assertNull(OnboardingStep.WHAT_IS_PEERING.previous())
        assertEquals(OnboardingStep.SCAN_CODE, OnboardingStep.INSTALL_HOST.next())
        assertNull(OnboardingStep.SCAN_CODE.next())
    }
}
