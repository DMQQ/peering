package pl.dmq.peering.ui.wiring

import pl.dmq.peering.billing.Billing

/** The billing port before a store is bound: no entitlement is known, so none is granted. */
internal object UnboundBilling : Billing {
    override suspend fun hasPaidRelayAccess(): Boolean = false
}
