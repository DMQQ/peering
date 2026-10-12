package pl.dmq.peering.billing

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.relay.RelayEntitlement

/** Paid relay time as this phone knows it: whether an active purchase exists, and what the relay is sent with. */
interface Billing {
    /** True while an active pro purchase is known to this phone. */
    val paidRelay: StateFlow<Boolean>

    /** The entitlement each relayed session presents: the active purchase, or none. */
    fun entitlement(): RelayEntitlement
}
