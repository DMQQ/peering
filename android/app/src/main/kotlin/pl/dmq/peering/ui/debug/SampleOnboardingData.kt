package pl.dmq.peering.ui.debug

import pl.dmq.peering.feature.onboarding.FirstRunStore
import pl.dmq.peering.feature.paywall.PaywallBilling
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.feature.paywall.PurchaseOutcome
import pl.dmq.peering.feature.paywall.RestoreOutcome

/** Debug previews only: a first run that never completes and offers priced like the iPhone's. */
internal object SampleFirstRun : FirstRunStore {
    override fun isComplete(): Boolean = false

    override fun markComplete() = Unit
}

internal object SampleBilling : PaywallBilling {
    override suspend fun products() = listOf(
        PaywallProduct(PlanOffer.MONTHLY, "monthly", "$4.99"),
        PaywallProduct(PlanOffer.LIFETIME, "lifetime", "$39.99"),
    )

    override suspend fun purchase(productID: String) = PurchaseOutcome.CANCELLED

    override suspend fun restore() = RestoreOutcome.NOTHING_TO_RESTORE

    override suspend fun hasPaidRelayAccess() = false
}
