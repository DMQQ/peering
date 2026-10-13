package pl.dmq.peering.feature.paywall

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import kotlinx.coroutines.flow.StateFlow

/**
 * The paywall feature as one screen. It opens on the allowance notice when the relay has spent the free time, or on the
 * plans otherwise; the notice's own button leads to the plans.
 */
@Composable
fun PaywallRoute(
    billing: PaywallBilling,
    allowance: StateFlow<RelayAllowance>,
    reason: PaywallReason,
    startsWithAllowanceNotice: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val plans = remember(billing) { PaywallPresenter(billing, scope) }
    val allowanceUi = remember(allowance) { AllowanceSpentPresenter(allowance, scope) }
    val allowanceState by allowanceUi.ui.collectAsState()
    var showingNotice by remember { mutableStateOf(startsWithAllowanceNotice) }

    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        if (showingNotice) {
            AllowanceSpentScreen(
                ui = allowanceState,
                onSeePlans = { showingNotice = false },
                onDismiss = onDismiss,
            )
        } else {
            PaywallScreen(presenter = plans, reason = reason, onDismiss = onDismiss)
        }
    }
}
