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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
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
import pl.dmq.peering.feature.settings.diagnosticsText
import pl.dmq.peering.ui.kit.DepthTransition
import pl.dmq.peering.ui.nav.LocalRootChrome
import pl.dmq.peering.ui.nav.PeeringDestination
import pl.dmq.peering.ui.wiring.StorePaywallBilling
import pl.dmq.peering.ui.wiring.composeEmail
import pl.dmq.peering.ui.wiring.findActivity
import pl.dmq.peering.ui.wiring.openWebPage
import pl.dmq.peering.ui.wiring.shareText
import pl.dmq.peering.ui.wiring.rememberAppProtection

private const val SUPPORT_ADDRESS = "support@getpeering.app"

/** The Settings tab: its preferences, the plans it can open, and the legal pages opened over it in the app. */
@Composable
internal fun SettingsTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
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
    val actions = rememberSettingsActions(wiring, version, onOpenLegal = { legal = it }, onSeePlans = { plans = true })
    BackHandler(enabled = legal != null) { legal = null }
    BackHandler(enabled = legal == null && plans) { plans = false }
    val page = legal?.let { SettingsPage.Legal(it) } ?: if (plans) SettingsPage.Plans else SettingsPage.Root
    DepthTransition(state = page, depth = { if (it == SettingsPage.Root) 0 else 1 }, label = "settingsPage") { shown ->
        SettingsPageContent(shown, wiring, presenter, actions, onDismissPlans = { plans = false })
    }
}

@Composable
private fun rememberSettingsActions(
    wiring: FeatureWiring,
    version: String,
    onOpenLegal: (LegalDocument) -> Unit,
    onSeePlans: () -> Unit,
): SettingsActions {
    val context = LocalContext.current
    val chrome = LocalRootChrome.current
    val clipboard = LocalClipboardManager.current
    val reportSubject = stringResource(R.string.settings_report_subject)
    val reportBody = stringResource(R.string.settings_report_body, version, Build.VERSION.RELEASE)
    return SettingsActions(
        onOpenLegal = onOpenLegal,
        onSeePlans = onSeePlans,
        onGetHostApp = { context.openWebPage(DOWNLOAD_URL) },
        onShowIntroduction = {
            wiring.firstRun.reset()
            chrome.open(PeeringDestination.Connect)
        },
        onReportIssue = { context.composeEmail(SUPPORT_ADDRESS, reportSubject, reportBody) },
        onOpenWebPage = { context.openWebPage(it) },
        onShareInvite = { context.shareText(it) },
        onCopyDiagnostics = { state ->
            val text = diagnosticsText(version, Build.VERSION.RELEASE, Build.MODEL, state.deviceId, state.trustedHosts.size, state.prefs.allowsRelay, state.relayUnlimited)
            clipboard.setText(AnnotatedString(text))
        },
        protection = rememberAppProtection(),
    )
}

@Composable
private fun SettingsPageContent(
    shown: SettingsPage,
    wiring: FeatureWiring,
    presenter: SettingsPresenter,
    actions: SettingsActions,
    onDismissPlans: () -> Unit,
) {
    val context = LocalContext.current
    when (shown) {
        is SettingsPage.Legal -> LegalPageScreen(document = shown.document, onOpenWebPage = { context.openWebPage(it) })
        SettingsPage.Plans -> PaywallRoute(
            billing = remember(wiring) { StorePaywallBilling(wiring.billing) { context.findActivity() } },
            allowance = wiring.relayAllowance.allowance,
            reason = PaywallReason.Upgrade,
            startsWithAllowanceNotice = false,
            onDismiss = onDismissPlans,
        )
        SettingsPage.Root -> SettingsRoute(presenter = presenter, invites = wiring.invites, nowSeconds = wiring.clock::unixSeconds, actions = actions)
    }
}

private sealed interface SettingsPage {
    data object Root : SettingsPage
    data object Plans : SettingsPage
    data class Legal(val document: LegalDocument) : SettingsPage
}
