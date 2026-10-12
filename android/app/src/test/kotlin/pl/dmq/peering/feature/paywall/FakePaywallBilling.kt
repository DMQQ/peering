package pl.dmq.peering.feature.paywall

class FakePaywallBilling(
    var products: List<PaywallProduct> = listOf(
        PaywallProduct(PlanOffer.SUBSCRIPTION, "relay_monthly", "2.99"),
        PaywallProduct(PlanOffer.LIFETIME, "relay_lifetime", "19.99"),
    ),
    var productsError: Exception? = null,
    var purchaseOutcome: PurchaseOutcome = PurchaseOutcome.PURCHASED,
    var restoreOutcome: RestoreOutcome = RestoreOutcome.RESTORED,
    var entitled: Boolean = false,
) : PaywallBilling {
    val purchases = mutableListOf<String>()
    var restores = 0
        private set

    override suspend fun products(): List<PaywallProduct> {
        productsError?.let { throw it }
        return products
    }

    override suspend fun purchase(productID: String): PurchaseOutcome {
        purchases += productID
        return purchaseOutcome
    }

    override suspend fun restore(): RestoreOutcome {
        restores++
        return restoreOutcome
    }

    override suspend fun hasPaidRelayAccess(): Boolean = entitled
}
