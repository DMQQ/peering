package pl.dmq.peering.feature.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingPresenterTest {
    @Test
    fun startsOnTheLandingWithNothingCompleted() {
        val ui = OnboardingPresenter(FakeFirstRunStore()).ui.value
        assertEquals(OnboardingStep.LANDING, ui.step)
        assertFalse(ui.completed)
    }

    @Test
    fun nextWalksTheTourInOrderAndEndsOnThePlans() {
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        val seen = mutableListOf(presenter.ui.value.step)
        repeat(OnboardingStep.pageCount) {
            presenter.next()
            seen += presenter.ui.value.step
        }
        assertEquals(OnboardingStep.entries, seen)
        assertTrue(presenter.ui.value.isLast)
    }

    @Test
    fun thePlansPageIsTheEighthPageAndLandingHasNoPageIndex() {
        assertEquals(8, OnboardingStep.pageCount)
        assertEquals(7, OnboardingStep.PLANS.pageIndex)
        assertEquals(0, OnboardingStep.INSTALL.pageIndex)
        assertNull(OnboardingStep.LANDING.pageIndex)
    }

    @Test
    fun finishingTheLastPageSetsThePersistenceFlagOnce() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        repeat(OnboardingStep.entries.size) { presenter.next() }
        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
        presenter.next()
        presenter.skip()
        assertEquals(1, store.marks)
    }

    @Test
    fun skippingTheLandingCompletesTheFirstRun() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        presenter.skip()
        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
    }

    @Test
    fun skippingInsideTheTourJumpsToThePlansWithoutCompleting() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        presenter.next()
        presenter.next()
        presenter.skip()
        assertEquals(OnboardingStep.PLANS, presenter.ui.value.step)
        assertFalse(presenter.ui.value.completed)
        presenter.skip()
        assertTrue(presenter.ui.value.completed)
    }

    @Test
    fun aFirstRunThatWasFinishedBeforeStaysCompleted() {
        val presenter = OnboardingPresenter(FakeFirstRunStore(complete = true))
        assertTrue(presenter.ui.value.completed)
        presenter.next()
        assertEquals(OnboardingStep.LANDING, presenter.ui.value.step)
    }

    @Test
    fun stepsKnowTheirNeighboursAndTheLandingIsNotATourPageToReturnTo() {
        assertNull(OnboardingStep.LANDING.previous())
        assertEquals(OnboardingStep.PAIR, OnboardingStep.INSTALL.next())
        assertNull(OnboardingStep.PLANS.next())
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        presenter.goTo(OnboardingStep.LANDING)
        assertEquals(OnboardingStep.LANDING, presenter.ui.value.step)
    }

    @Test
    fun backFromTheFirstTourPageReturnsToTheLandingAndFromTheLandingDoesNothing() {
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        presenter.next()
        assertTrue(presenter.back())
        assertEquals(OnboardingStep.LANDING, presenter.ui.value.step)
        assertFalse(presenter.back())
    }

    @Test
    fun finishFromAnyPageCompletesTheFirstRunAndPersistsIt() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store)
        presenter.next()

        presenter.finish()

        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
        assertEquals(1, store.marks)
    }

    @Test
    fun startingFreeOnThePlansPageCompletesAndPersistsTheFirstRun() {
        val store = FakeFirstRunStore()
        val presenter = OnboardingPresenter(store, startAt = OnboardingStep.PLANS)

        val action = plansAction(onPlans = true, freeChosen = true, entitled = false, hasProducts = true)
        if (action == PlansAction.Finish) presenter.finish()

        assertEquals(PlansAction.Finish, action)
        assertTrue(presenter.ui.value.completed)
        assertTrue(store.isComplete())
    }

    @Test
    fun backWalksEveryTourPageToTheLandingInReverse() {
        val presenter = OnboardingPresenter(FakeFirstRunStore(), startAt = OnboardingStep.PLANS)
        val seen = mutableListOf(presenter.ui.value.step)
        while (presenter.back()) seen += presenter.ui.value.step
        assertEquals(OnboardingStep.entries.reversed(), seen)
    }

    @Test
    fun goToJumpsBetweenTourPagesAndIsIgnoredOnceCompleted() {
        val presenter = OnboardingPresenter(FakeFirstRunStore())
        presenter.goTo(OnboardingStep.MOSAIC)
        assertEquals(OnboardingStep.MOSAIC, presenter.ui.value.step)
        presenter.finish()
        presenter.goTo(OnboardingStep.PAIR)
        assertEquals(OnboardingStep.MOSAIC, presenter.ui.value.step)
    }
}
