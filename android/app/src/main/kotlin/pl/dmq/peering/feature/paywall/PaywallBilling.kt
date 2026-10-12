package pl.dmq.peering.feature.paywall

/** The ways to pay for unlimited relay time: the two subscription periods, and the one-time lifetime purchase. */
enum class PlanOffer {
    MONTHLY,
    YEARLY,
    LIFETIME,
}

/** A purchasable offer as the store prices it. [displayPrice] is the store's own text, never formatted here. */
data class PaywallProduct(
    val offer: PlanOffer,
    val productID: String,
    val displayPrice: String,
)

enum class PurchaseOutcome {
    PURCHASED,
    PENDING,
    CANCELLED,
    FAILED,
}

enum class RestoreOutcome {
    RESTORED,
    NOTHING_TO_RESTORE,
    FAILED,
}

/**
 * What the paywall needs from the store. [products] throws [PaywallUnavailable] when the store cannot give the offers;
 * the purchase and restore calls report their outcome instead.
 */
interface PaywallBilling {
    suspend fun products(): List<PaywallProduct>

    suspend fun purchase(productID: String): PurchaseOutcome

    suspend fun restore(): RestoreOutcome

    suspend fun hasPaidRelayAccess(): Boolean
}
