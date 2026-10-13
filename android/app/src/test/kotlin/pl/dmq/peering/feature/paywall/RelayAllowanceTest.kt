package pl.dmq.peering.feature.paywall

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayAllowanceTest {
    @Test
    fun freeTimeIsThirtyMinutesAndCountsDown() {
        val allowance = RelayAllowance(usedSeconds = 600, paid = false)
        assertEquals(1_200L, allowance.remainingSeconds)
        assertFalse(allowance.isSpent)
    }

    @Test
    fun aFreeAllowanceUsedUpIsSpentAndNeverNegative() {
        val spent = RelayAllowance(usedSeconds = 1_900, paid = false)
        assertEquals(0L, spent.remainingSeconds)
        assertTrue(spent.isSpent)
    }

    @Test
    fun paidAccessHasNoLimitToSpend() {
        val paid = RelayAllowance(usedSeconds = 99_999, paid = true)
        assertFalse(paid.isSpent)
    }

    @Test
    fun allowanceScreenShowsTheRemainingTimeAndTheDailyLimit() {
        val ui = AllowanceUi.of(RelayAllowance(usedSeconds = 1_200, paid = false))
        assertEquals(RemainingLabel.Minutes(10), ui.remaining)
        assertEquals(RemainingLabel.Minutes(30), ui.dailyLimit)
        assertFalse(ui.spent)
    }
}
