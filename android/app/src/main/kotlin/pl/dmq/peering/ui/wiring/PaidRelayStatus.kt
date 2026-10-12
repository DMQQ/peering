package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.billing.Billing

/** Whether this phone has paid relay time, as the billing port last reported it. */
internal class PaidRelayStatus(private val billing: Billing) {
    private val mutablePaid = MutableStateFlow(false)

    val paid: StateFlow<Boolean> = mutablePaid.asStateFlow()

    suspend fun refresh() {
        mutablePaid.value = billing.hasPaidRelayAccess()
    }
}
