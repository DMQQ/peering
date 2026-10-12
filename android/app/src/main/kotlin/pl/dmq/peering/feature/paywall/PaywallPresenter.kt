package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The paywall's state machine over the store: loading the offers, choosing one, buying it, and restoring purchases. */
class PaywallPresenter(
    private val billing: PaywallBilling,
    private val scope: CoroutineScope,
) {
    private val model = MutableStateFlow(PaywallUi())
    val ui: StateFlow<PaywallUi> = model.asStateFlow()

    init {
        load()
    }

    fun load() {
        model.update { it.copy(loading = true, loadFailed = false) }
        scope.launch {
            val loaded = try {
                billing.products() to true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                emptyList<PaywallProduct>() to false
            }
            val entitled = billing.hasPaidRelayAccess()
            model.update { current ->
                current.copy(
                    loading = false,
                    products = loaded.first,
                    loadFailed = !loaded.second,
                    selected = current.selected ?: loaded.first.firstOrNull { it.offer == PlanOffer.SUBSCRIPTION }?.offer
                        ?: loaded.first.firstOrNull()?.offer,
                    entitled = entitled,
                )
            }
        }
    }

    fun select(offer: PlanOffer) {
        if (model.value.products.any { it.offer == offer }) model.update { it.copy(selected = offer) }
    }

    fun buy() {
        val current = model.value
        if (!current.canBuy) return
        val product = current.products.firstOrNull { it.offer == current.selected } ?: return
        model.update { it.copy(purchase = PurchaseState.PURCHASING) }
        scope.launch {
            val outcome = billing.purchase(product.productID)
            model.update {
                it.copy(
                    purchase = purchaseState(outcome),
                    entitled = it.entitled || outcome == PurchaseOutcome.PURCHASED,
                )
            }
        }
    }

    fun restore() {
        if (model.value.restore == RestoreState.RESTORING) return
        model.update { it.copy(restore = RestoreState.RESTORING) }
        scope.launch {
            val outcome = billing.restore()
            model.update {
                it.copy(
                    restore = restoreState(outcome),
                    entitled = it.entitled || outcome == RestoreOutcome.RESTORED,
                )
            }
        }
    }

    private fun purchaseState(outcome: PurchaseOutcome): PurchaseState = when (outcome) {
        PurchaseOutcome.PURCHASED -> PurchaseState.PURCHASED
        PurchaseOutcome.PENDING -> PurchaseState.AWAITING_APPROVAL
        PurchaseOutcome.CANCELLED -> PurchaseState.CANCELLED
        PurchaseOutcome.FAILED -> PurchaseState.FAILED
    }

    private fun restoreState(outcome: RestoreOutcome): RestoreState = when (outcome) {
        RestoreOutcome.RESTORED -> RestoreState.RESTORED
        RestoreOutcome.NOTHING_TO_RESTORE -> RestoreState.NOTHING_TO_RESTORE
        RestoreOutcome.FAILED -> RestoreState.FAILED
    }
}
