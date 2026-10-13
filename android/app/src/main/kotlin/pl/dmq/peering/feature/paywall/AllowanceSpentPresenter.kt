package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** Turns the day's relay usage into what the allowance screen shows. */
class AllowanceSpentPresenter(
    allowance: StateFlow<RelayAllowance>,
    scope: CoroutineScope,
) {
    val ui: StateFlow<AllowanceUi> = allowance
        .map { AllowanceUi.of(it) }
        .stateIn(scope, SharingStarted.Eagerly, AllowanceUi.of(allowance.value))
}
