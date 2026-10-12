package pl.dmq.peering.feature.paywall

/** The two ways to pay for unlimited relay time. */
enum class PlanOffer {
    SUBSCRIPTION,
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
 * What the paywall needs from the store. The store implementation is chosen per distribution and is not bound yet.
 * [products] may throw when the store cannot be reached; the purchase and restore calls report their outcome instead.
 */
interface PaywallBilling {
    suspend fun products(): List<PaywallProduct>

    suspend fun purchase(productID: String): PurchaseOutcome

    suspend fun restore(): RestoreOutcome

    suspend fun hasPaidRelayAccess(): Boolean
}
