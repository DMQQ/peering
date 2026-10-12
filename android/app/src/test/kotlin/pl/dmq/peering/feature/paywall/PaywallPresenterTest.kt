package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PaywallPresenterTest {
    private fun presenter(billing: FakePaywallBilling) = PaywallPresenter(billing, CoroutineScope(UnconfinedTestDispatcher()))

    @Test
    fun offersLoadAndTheSubscriptionIsPreselected() = runTest {
        val ui = presenter(FakePaywallBilling()).ui.value
        assertFalse(ui.loading)
        assertEquals(2, ui.products.size)
        assertEquals(PlanOffer.SUBSCRIPTION, ui.selected)
        assertFalse(ui.loadFailed)
    }

    @Test
    fun aStoreThatCannotBeReachedShowsAFailedLoadWithNoOffers() = runTest {
        val ui = presenter(FakePaywallBilling(productsError = IllegalStateException("offline"))).ui.value
        assertTrue(ui.loadFailed)
        assertFalse(ui.loading)
        assertTrue(ui.products.isEmpty())
        assertEquals(null, ui.selected)
    }

    @Test
    fun aPaidDeviceNeedsNoPurchaseAndCannotBuy() = runTest {
        val presenter = presenter(FakePaywallBilling(entitled = true))
        assertTrue(presenter.ui.value.entitled)
        assertFalse(presenter.ui.value.canBuy)
    }

    @Test
    fun selectingAnOfferChangesWhatIsBought() = runTest {
        val billing = FakePaywallBilling()
        val presenter = presenter(billing)
        presenter.select(PlanOffer.LIFETIME)
        presenter.buy()
        assertEquals(listOf("relay_lifetime"), billing.purchases)
    }

    @Test
    fun aPurchaseThatGoesThroughUnlocksTheRelay() = runTest {
        val presenter = presenter(FakePaywallBilling(purchaseOutcome = PurchaseOutcome.PURCHASED))
        presenter.buy()
        assertEquals(PurchaseState.PURCHASED, presenter.ui.value.purchase)
        assertTrue(presenter.ui.value.entitled)
        assertFalse(presenter.ui.value.canBuy)
    }

    @Test
    fun aPendingPurchaseWaitsForApprovalAndDoesNotUnlockYet() = runTest {
        val presenter = presenter(FakePaywallBilling(purchaseOutcome = PurchaseOutcome.PENDING))
        presenter.buy()
        assertEquals(PurchaseState.AWAITING_APPROVAL, presenter.ui.value.purchase)
        assertFalse(presenter.ui.value.entitled)
    }

    @Test
    fun aCancelledOrFailedPurchaseLeavesTheOfferBuyable() = runTest {
        val cancelled = presenter(FakePaywallBilling(purchaseOutcome = PurchaseOutcome.CANCELLED))
        cancelled.buy()
        assertEquals(PurchaseState.CANCELLED, cancelled.ui.value.purchase)
        assertTrue(cancelled.ui.value.canBuy)

        val failed = presenter(FakePaywallBilling(purchaseOutcome = PurchaseOutcome.FAILED))
        failed.buy()
        assertEquals(PurchaseState.FAILED, failed.ui.value.purchase)
        assertTrue(failed.ui.value.canBuy)
    }

    @Test
    fun aRestoreThatFindsAPurchaseUnlocksTheRelay() = runTest {
        val presenter = presenter(FakePaywallBilling(restoreOutcome = RestoreOutcome.RESTORED))
        presenter.restore()
        assertEquals(RestoreState.RESTORED, presenter.ui.value.restore)
        assertTrue(presenter.ui.value.entitled)
    }

    @Test
    fun aRestoreWithNothingToFindSaysSo() = runTest {
        val presenter = presenter(FakePaywallBilling(restoreOutcome = RestoreOutcome.NOTHING_TO_RESTORE))
        presenter.restore()
        assertEquals(RestoreState.NOTHING_TO_RESTORE, presenter.ui.value.restore)
        assertFalse(presenter.ui.value.entitled)
    }

    @Test
    fun buyingWithoutAnyOfferDoesNothing() = runTest {
        val billing = FakePaywallBilling(products = emptyList())
        val presenter = presenter(billing)
        presenter.buy()
        assertTrue(billing.purchases.isEmpty())
    }

    @Test
    fun aMissingOfferCannotBeSelected() = runTest {
        val presenter = presenter(FakePaywallBilling(products = listOf(PaywallProduct(PlanOffer.LIFETIME, "x", "1"))))
        presenter.select(PlanOffer.SUBSCRIPTION)
        assertEquals(PlanOffer.LIFETIME, presenter.ui.value.selected)
    }

    @Test
    fun retryReloadsTheOffers() = runTest {
        val billing = FakePaywallBilling(productsError = IllegalStateException("offline"))
        val presenter = presenter(billing)
        billing.productsError = null
        presenter.load()
        assertFalse(presenter.ui.value.loadFailed)
        assertEquals(2, presenter.ui.value.products.size)
    }
}
