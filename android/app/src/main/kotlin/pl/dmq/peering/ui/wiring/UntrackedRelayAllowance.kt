package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.paywall.RelayAllowance

/**
 * The day's relay time used. This build does not record it yet, so the flow holds nothing used and no paid plan: the
 * allowance reads as unknown rather than as spent.
 */
internal object UntrackedRelayAllowance {
    val allowance: StateFlow<RelayAllowance> = MutableStateFlow(RelayAllowance(usedSeconds = 0, paid = false))
}
