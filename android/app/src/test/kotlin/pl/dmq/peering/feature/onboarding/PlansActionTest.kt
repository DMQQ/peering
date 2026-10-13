package pl.dmq.peering.feature.onboarding

import org.junit.Assert.assertEquals
import org.junit.Test

class PlansActionTest {
    @Test
    fun beforeThePlansPageTheButtonTurnsThePage() {
        assertEquals(PlansAction.Next, plansAction(onPlans = false, freeChosen = true, entitled = true, hasProducts = true))
    }

    @Test
    fun choosingFreeLeavesTheFirstRunEvenWithPlansOnOffer() {
        assertEquals(PlansAction.Finish, plansAction(onPlans = true, freeChosen = true, entitled = false, hasProducts = true))
    }

    @Test
    fun aPaidPlanStartsABuyOnlyWhenOneIsChosenAndOffered() {
        assertEquals(PlansAction.Buy, plansAction(onPlans = true, freeChosen = false, entitled = false, hasProducts = true))
    }

    @Test
    fun withNothingToBuyOrAlreadyOwningThePageJustFinishes() {
        assertEquals(PlansAction.Finish, plansAction(onPlans = true, freeChosen = false, entitled = false, hasProducts = false))
        assertEquals(PlansAction.Finish, plansAction(onPlans = true, freeChosen = false, entitled = true, hasProducts = true))
    }
}
