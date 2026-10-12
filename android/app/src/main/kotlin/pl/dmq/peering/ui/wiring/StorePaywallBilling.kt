package pl.dmq.peering.ui.wiring

import pl.dmq.peering.billing.Billing
import pl.dmq.peering.feature.paywall.PaywallBilling
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PurchaseOutcome
import pl.dmq.peering.feature.paywall.RestoreOutcome

/**
 * The paywall over the billing port. No store is bound yet, so the products cannot load: the paywall shows that it could
 * not load them, and purchase and restore report failure rather than succeed.
 */
internal class StorePaywallBilling(private val billing: Billing) : PaywallBilling {
    override suspend fun products(): List<PaywallProduct> = throw IllegalStateException(BILLING_UNAVAILABLE)

    override suspend fun purchase(productID: String): PurchaseOutcome = PurchaseOutcome.FAILED

    override suspend fun restore(): RestoreOutcome = RestoreOutcome.FAILED

    override suspend fun hasPaidRelayAccess(): Boolean = billing.hasPaidRelayAccess()

    private companion object {
        const val BILLING_UNAVAILABLE = "billing unavailable"
    }
}
