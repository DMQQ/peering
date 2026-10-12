package pl.dmq.peering.billing

/** Why relay purchases cannot be offered on this phone. Each reason gets its own explanation on the paywall. */
sealed interface BillingUnavailable {
    /** Google Play Billing is not supported on this device or store. */
    data object NotSupported : BillingUnavailable

    /** The store could not be reached after the retries. */
    data object StoreUnreachable : BillingUnavailable

    /** The store answered, but none of the relay products is set up for this app. */
    data object NotConfigured : BillingUnavailable

    /** The store refused the request with a response code this app does not expect. */
    data class Refused(val responseCode: Int) : BillingUnavailable
}

/** A relay product as the store prices it. [displayPrice] is the store's text, never formatted here. */
data class StoreOffer(
    val productID: String,
    val displayPrice: String,
)

sealed interface BillingState {
    data object Connecting : BillingState

    data class Ready(val offers: List<StoreOffer>) : BillingState

    data class Unavailable(val reason: BillingUnavailable) : BillingState
}
