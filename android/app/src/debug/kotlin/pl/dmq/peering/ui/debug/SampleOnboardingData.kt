package pl.dmq.peering.ui.debug

import pl.dmq.peering.feature.onboarding.FirstRunStore
import pl.dmq.peering.feature.paywall.PaywallBilling
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.feature.paywall.PurchaseOutcome
import pl.dmq.peering.feature.paywall.RestoreOutcome

/** Debug previews only: a first run that never completes and offers priced like the iPhone's. */
internal object SampleFirstRun : FirstRunStore {
    private var complete = false

    override fun isComplete(): Boolean = complete

    override fun markComplete() {
        complete = true
    }
}

internal object SampleBilling : PaywallBilling {
    override suspend fun products() = listOf(
        PaywallProduct(PlanOffer.MONTHLY, "monthly", "$2.99"),
        PaywallProduct(PlanOffer.LIFETIME, "lifetime", "$24.99"),
    )

    override suspend fun purchase(productID: String) = PurchaseOutcome.CANCELLED

    override suspend fun restore() = RestoreOutcome.NOTHING_TO_RESTORE

    override suspend fun hasPaidRelayAccess() = false
}
