package pl.dmq.peering.session.relay

/** What the client can prove about its plan. Every field is optional: without one the relay meters the free time. */
data class RelayEntitlement(
    val plan: String? = null,
    val playPurchaseToken: String? = null,
    val playProductId: String? = null,
)
