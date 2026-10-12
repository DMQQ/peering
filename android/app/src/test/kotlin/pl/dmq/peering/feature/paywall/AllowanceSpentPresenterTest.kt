package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AllowanceSpentPresenterTest {
    @Test
    fun theScreenFollowsTheAllowanceAsItIsSpent() = runTest {
        val allowance = MutableStateFlow(RelayAllowance(usedSeconds = 0, paid = false))
        val presenter = AllowanceSpentPresenter(allowance, CoroutineScope(UnconfinedTestDispatcher()))
        assertEquals(RemainingLabel.Minutes(30), presenter.ui.value.remaining)
        allowance.value = RelayAllowance(usedSeconds = 1_800, paid = false)
        assertTrue(presenter.ui.value.spent)
        assertEquals(RemainingLabel.None, presenter.ui.value.remaining)
    }

    @Test
    fun aPaidDeviceIsNeverShownAsSpent() = runTest {
        val allowance = MutableStateFlow(RelayAllowance(usedSeconds = 9_999, paid = true))
        val presenter = AllowanceSpentPresenter(allowance, CoroutineScope(UnconfinedTestDispatcher()))
        assertEquals(false, presenter.ui.value.spent)
        assertTrue(presenter.ui.value.paid)
    }
}
