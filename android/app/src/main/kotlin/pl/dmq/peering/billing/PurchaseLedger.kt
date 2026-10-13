package pl.dmq.peering.billing

import pl.dmq.peering.session.relay.RelayEntitlement

/** One purchase as Play reports it, reduced to what the relay and the acknowledgement need. */
data class OwnedPurchase(
    val productID: String,
    val token: String,
    val purchased: Boolean,
    val acknowledged: Boolean,
)

/** The purchase that grants unlimited relay time, or null when none is active. Pending and unpaid purchases do not count. */
fun activeProPurchase(purchases: List<OwnedPurchase>): OwnedPurchase? =
    purchases.firstOrNull { it.purchased && it.productID in PlayProducts.paid }

/** What the relay is sent with each session: the pro plan and the purchase it can verify, or nothing. */
fun entitlementFor(purchase: OwnedPurchase?): RelayEntitlement =
    if (purchase == null) {
        RelayEntitlement()
    } else {
        RelayEntitlement(plan = PRO_PLAN, playPurchaseToken = purchase.token, playProductId = purchase.productID)
    }

/** Purchases Play requires to be acknowledged, or they are refunded after three days. */
fun unacknowledged(purchases: List<OwnedPurchase>): List<OwnedPurchase> =
    purchases.filter { it.purchased && !it.acknowledged }

private const val PRO_PLAN = "pro"
