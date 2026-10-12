package pl.dmq.peering.billing

// Port for paid relay time. The store implementation is chosen per distribution and is not bound yet.
interface Billing {
    suspend fun hasPaidRelayAccess(): Boolean
}
