package pl.dmq.peering.ui

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.feature.onboarding.DOWNLOAD_URL
import pl.dmq.peering.feature.paywall.PaywallReason
import pl.dmq.peering.feature.paywall.PaywallRoute
import pl.dmq.peering.feature.settings.LegalDocument
import pl.dmq.peering.feature.settings.LegalPageScreen
import pl.dmq.peering.feature.settings.SettingsActions
import pl.dmq.peering.feature.settings.SettingsPresenter
import pl.dmq.peering.feature.settings.SettingsRoute
import pl.dmq.peering.ui.nav.LocalRootChrome
import pl.dmq.peering.ui.nav.PeeringDestination
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.composeEmail
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.ui.wiring.openWebPage
import pl.dmq.peering.ui.wiring.rememberAppProtection

private const val SUPPORT_ADDRESS = "support@getpeering.app"

/** The Settings tab: its preferences, the plans it can open, and the legal pages opened over it in the app. */
@Composable
internal fun SettingsTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val chrome = LocalRootChrome.current
    var legal by rememberSaveable { mutableStateOf<LegalDocument?>(null) }
    var plans by rememberSaveable { mutableStateOf(false) }
    val version = remember(context) { context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty() }
    val presenter = remember(wiring, scope) {
        SettingsPresenter(
            trusted = wiring.trusted,
            preferences = wiring.settings,
            devicePrefs = wiring.devicePrefs,
            deviceId = wiring.deviceId,
            paidRelay = wiring.billing.paidRelay,
            appVersion = version,
            scope = scope,
        )
    }
    val reportSubject = stringResource(R.string.settings_report_subject)
    val reportBody = stringResource(R.string.settings_report_body, version, Build.VERSION.RELEASE)
    val actions = SettingsActions(
        onOpenLegal = { legal = it },
        onSeePlans = { plans = true },
        onGetHostApp = { context.openWebPage(DOWNLOAD_URL) },
        onShowIntroduction = {
            wiring.firstRun.reset()
            chrome.open(PeeringDestination.Connect)
        },
        onReportIssue = { context.composeEmail(SUPPORT_ADDRESS, reportSubject, reportBody) },
        protection = rememberAppProtection(),
    )
    val document = legal
    when {
        document != null -> {
            BackHandler { legal = null }
            LegalPageScreen(document = document, onOpenWebPage = { context.openWebPage(it) })
        }
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
        else -> SettingsRoute(presenter = presenter, actions = actions)
    }
}
