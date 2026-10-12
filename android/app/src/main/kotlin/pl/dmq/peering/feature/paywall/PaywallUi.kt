package pl.dmq.peering.feature.paywall

import pl.dmq.peering.billing.BillingUnavailable

enum class PurchaseState {
    IDLE,
    PURCHASING,
    AWAITING_APPROVAL,
    PURCHASED,
    CANCELLED,
    FAILED,
}

enum class RestoreState {
    IDLE,
    RESTORING,
    RESTORED,
    NOTHING_TO_RESTORE,
    FAILED,
}

data class PaywallUi(
    val loading: Boolean = true,
    val products: List<PaywallProduct> = emptyList(),
    val loadFailed: Boolean = false,
    val unavailable: BillingUnavailable? = null,
    val selected: PlanOffer? = null,
    val entitled: Boolean = false,
    val purchase: PurchaseState = PurchaseState.IDLE,
    val restore: RestoreState = RestoreState.IDLE,
) {
    val canBuy: Boolean get() = !entitled && selected != null && purchase != PurchaseState.PURCHASING
}

/** Why the paywall was opened. The copy for each is chosen by the screen. */
sealed interface PaywallReason {
    data object Upgrade : PaywallReason

    data object RelayTimeSpent : PaywallReason

    data class RunningLow(val remainingSeconds: Long) : PaywallReason
}
