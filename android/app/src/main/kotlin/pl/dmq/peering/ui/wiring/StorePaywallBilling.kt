package pl.dmq.peering.ui.wiring

import android.app.Activity
import kotlinx.coroutines.flow.first
import pl.dmq.peering.billing.BillingState
import pl.dmq.peering.billing.BillingUnavailable
import pl.dmq.peering.billing.PlayBilling
import pl.dmq.peering.billing.PlayProducts
import pl.dmq.peering.billing.PurchaseResult
import pl.dmq.peering.billing.RestoreResult
import pl.dmq.peering.feature.paywall.PaywallBilling
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PaywallUnavailable
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.feature.paywall.PurchaseOutcome
import pl.dmq.peering.feature.paywall.RestoreOutcome

/** The paywall over Google Play Billing. Offers wait for the store to settle; purchases need the screen's activity. */
internal class StorePaywallBilling(
    private val play: PlayBilling,
    private val activity: () -> Activity?,
) : PaywallBilling {
    override suspend fun products(): List<PaywallProduct> =
        when (val settled = play.state.first { it !is BillingState.Connecting }) {
            is BillingState.Ready -> settled.offers.mapNotNull { offer ->
                planOffer(offer.productID)?.let { PaywallProduct(it, offer.productID, offer.displayPrice) }
            }
            is BillingState.Unavailable -> throw PaywallUnavailable(settled.reason)
            BillingState.Connecting -> throw PaywallUnavailable(BillingUnavailable.StoreUnreachable)
        }

    override suspend fun purchase(productID: String): PurchaseOutcome {
        val host = activity() ?: return PurchaseOutcome.FAILED
        return when (play.purchase(host, productID)) {
            PurchaseResult.PURCHASED -> PurchaseOutcome.PURCHASED
            PurchaseResult.PENDING -> PurchaseOutcome.PENDING
            PurchaseResult.CANCELLED -> PurchaseOutcome.CANCELLED
            PurchaseResult.FAILED -> PurchaseOutcome.FAILED
        }
    }

    override suspend fun restore(): RestoreOutcome = when (play.restore()) {
        RestoreResult.RESTORED -> RestoreOutcome.RESTORED
        RestoreResult.NOTHING_TO_RESTORE -> RestoreOutcome.NOTHING_TO_RESTORE
        RestoreResult.FAILED -> RestoreOutcome.FAILED
    }

    override suspend fun hasPaidRelayAccess(): Boolean = play.paidRelay.value

    private fun planOffer(productID: String): PlanOffer? = when (productID) {
        PlayProducts.PRO_MONTHLY -> PlanOffer.MONTHLY
        PlayProducts.PRO_YEARLY -> PlanOffer.YEARLY
        PlayProducts.PRO_LIFETIME -> PlanOffer.LIFETIME
        else -> null
    }
}
