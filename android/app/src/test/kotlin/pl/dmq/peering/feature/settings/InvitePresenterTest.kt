@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.feature.settings

import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.relay.ReferralRefused
import pl.dmq.peering.wire.ReferralRefusal
import pl.dmq.peering.wire.RelayReferral

class InvitePresenterTest {
    private val standing = RelayReferral("ABCDEFGH", 1800, null, false, 0, 5)

    private class FakeService(var status: () -> RelayReferral, var redeem: (String) -> RelayReferral = { error("unused") }) : InviteService {
        val redeemed = mutableListOf<String>()

        override suspend fun status(): RelayReferral = status.invoke()

        override suspend fun redeem(typed: String): RelayReferral {
            redeemed += typed
            return redeem.invoke(typed)
        }
    }

    private fun TestScope.presenter(service: InviteService) = InvitePresenter(service, TestScope(UnconfinedTestDispatcher(testScheduler)))

    @Test
    fun refreshShowsTheRelaysStanding() = runTest {
        val presenter = presenter(FakeService({ standing }))

        presenter.refresh()

        assertEquals(standing, presenter.state.value.referral)
    }

    @Test
    fun aRelayThatIsDownLeavesWhatTheCardKnew() = runTest {
        val service = FakeService({ standing })
        val presenter = presenter(service)
        presenter.refresh()
        service.status = { throw IOException("down") }

        presenter.refresh()

        assertEquals(standing, presenter.state.value.referral)
        assertNull(presenter.state.value.failure)
    }

    @Test
    fun anIncompleteCodeIsRefusedWithoutAskingTheRelay() = runTest {
        val service = FakeService({ standing })
        val presenter = presenter(service)

        presenter.redeem("ABCD")

        assertEquals(ReferralRefusal.UnknownCode, presenter.state.value.failure)
        assertEquals(emptyList<String>(), service.redeemed)
    }

    @Test
    fun aRedeemedCodeReplacesTheStandingAndClearsAFailure() = runTest {
        val redeemed = standing.copy(redeemed = true)
        val service = FakeService({ standing }, { redeemed })
        val presenter = presenter(service)
        presenter.redeem("abc")

        presenter.redeem("abcd-efgh")

        assertEquals(InviteUiState(referral = redeemed), presenter.state.value)
        assertEquals(listOf("abcd-efgh"), service.redeemed)
    }

    @Test
    fun aRefusalIsShownAsTheRelayGaveIt() = runTest {
        val service = FakeService({ standing }, { throw ReferralRefused(ReferralRefusal.OwnCode) })
        val presenter = presenter(service)

        presenter.redeem("ABCDEFGH")

        assertEquals(ReferralRefusal.OwnCode, presenter.state.value.failure)
    }

    @Test
    fun everyRelayRefusalIsShownAsItsOwnMessage() = runTest {
        for (refusal in ReferralRefusal.entries) {
            val presenter = presenter(FakeService({ standing }, { throw ReferralRefused(refusal) }))

            presenter.redeem("ABCDEFGH")

            assertEquals(refusal, presenter.state.value.failure)
        }
    }

    @Test
    fun everyRefusalHasItsOwnStringResource() {
        val messages = ReferralRefusal.entries.map { it.messageRes() }

        assertEquals(ReferralRefusal.entries.size, messages.toSet().size)
    }

    @Test
    fun anUnreachableRelayIsShownAsUnavailable() = runTest {
        val service = FakeService({ standing }, { throw IOException("down") })
        val presenter = presenter(service)

        presenter.redeem("ABCDEFGH")

        assertEquals(ReferralRefusal.Unavailable, presenter.state.value.failure)
    }

    @Test
    fun theFooterFollowsTheStanding() {
        val running = standing.copy(bonusEndsAt = 2_000, invitesEarned = 2)

        assertEquals(InviteFooter.Send, inviteFooter(null, 0))
        assertEquals(InviteFooter.Running(30, 2_000, 2, 5), inviteFooter(running, nowSeconds = 1_999))
        assertEquals(InviteFooter.Idle(2, 5), inviteFooter(running, nowSeconds = 2_000))
    }

    @Test
    fun thePromptNamesTheBonusTheRelayReportedOrTheUsualThirty() {
        assertEquals(30, inviteBonusMinutes(null))
        assertEquals(30, inviteBonusMinutes(standing.copy(bonusSeconds = 0)))
        assertEquals(45, inviteBonusMinutes(standing.copy(bonusSeconds = 2_700)))
    }
}
