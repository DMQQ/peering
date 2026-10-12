package pl.dmq.peering.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.paywall.PaywallReason
import pl.dmq.peering.feature.paywall.PaywallRoute
import pl.dmq.peering.feature.settings.LegalDocument
import pl.dmq.peering.feature.settings.LegalPageScreen
import pl.dmq.peering.feature.settings.SettingsPresenter
import pl.dmq.peering.feature.settings.SettingsRoute
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.ui.wiring.openWebPage

/** The Settings tab: its preferences, the plans it can open, and the legal pages opened over it in the app. */
@Composable
internal fun SettingsTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var legal by rememberSaveable { mutableStateOf<LegalDocument?>(null) }
    var plans by rememberSaveable { mutableStateOf(false) }
    val presenter = remember(wiring, scope) {
        SettingsPresenter(
            trusted = wiring.trusted,
            preferences = wiring.settings,
            appVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty(),
            scope = scope,
        )
    }
    val document = legal
    when {
        document != null -> {
            BackHandler { legal = null }
            LegalPageScreen(document = document, onOpenWebPage = { context.openWebPage(it) })
        }
        plans -> {
            BackHandler { plans = false }
            PaywallRoute(
                billing = StorePaywallBilling(wiring.billing) { context.findActivity() },
                allowance = wiring.relayAllowance.allowance,
                reason = PaywallReason.Upgrade,
                startsWithAllowanceNotice = false,
                onDismiss = { plans = false },
            )
        }
        else -> SettingsRoute(presenter = presenter, onOpenLegal = { legal = it }, onSeePlans = { plans = true })
    }
}
