package pl.dmq.peering.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.paywall.PaywallReason
import pl.dmq.peering.feature.paywall.PaywallRoute
import pl.dmq.peering.feature.sessions.SessionDetail
import pl.dmq.peering.feature.sessions.SessionsScreen
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.findActivity
import androidx.compose.ui.platform.LocalContext

/** The Sessions tab: relay use and the recent sessions, a session's detail, and the plans the relay card opens. */
@Composable
internal fun SessionTab(wiring: FeatureWiring) {
    val context = LocalContext.current
    val records by wiring.sessionRecords.records.collectAsState()
    val allowance by wiring.relayAllowance.allowance.collectAsState()
    var openId by rememberSaveable { mutableStateOf<Long?>(null) }
    var plans by rememberSaveable { mutableStateOf(false) }
    val nowMillis = wiring.clock.unixSeconds() * MILLIS_PER_SECOND
    val opened = records.firstOrNull { it.id == openId }
    when {
        plans -> {
            BackHandler { plans = false }
            PaywallRoute(
                billing = remember(wiring) { StorePaywallBilling(wiring.billing) { context.findActivity() } },
                allowance = wiring.relayAllowance.allowance,
                reason = PaywallReason.Upgrade,
                startsWithAllowanceNotice = false,
                onDismiss = { plans = false },
            )
        }
        opened != null -> {
            BackHandler { openId = null }
            SessionDetail(opened, nowMillis, onBack = { openId = null }, modifier = Modifier)
        }
        else -> SessionsScreen(records, allowance, nowMillis, onUpgrade = { plans = true }, onOpen = { openId = it.id })
    }
}

private const val MILLIS_PER_SECOND = 1_000L
