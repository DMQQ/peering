package pl.dmq.peering.feature.paywall

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.billing.BillingUnavailable
import pl.dmq.peering.feature.onboarding.PlanOfferCards
import pl.dmq.peering.feature.onboarding.buttonTitle
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.kit.WelcomePrimaryButton
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop

/**
 * The plans (PaywallView.swift): header, plan rows and the renewal note in a scroll, the buy button and the three
 * links in a bar pinned under it.
 */
@Composable
fun PaywallScreen(
    presenter: PaywallPresenter,
    reason: PaywallReason,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    Column(modifier.fillMaxSize().peeringBackdrop()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(horizontal = 18.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            PaywallHeader(reason)
            Plans(ui, presenter)
            Footer(ui)
        }
        BuyBar(ui, presenter, onDismiss)
    }
}

@Composable
private fun Plans(ui: PaywallUi, presenter: PaywallPresenter) {
    when {
        ui.entitled -> Text(stringResource(R.string.paywall_already_unlimited), style = PeeringText.subheadlineSemibold, color = PeeringColors.added)
        ui.loading -> Row(Modifier.fillMaxWidth().padding(vertical = 32.dp), horizontalArrangement = Arrangement.Center) {
            PeeringSpinner(color = PeeringColors.ink)
        }
        ui.products.isEmpty() -> Unavailable(ui.unavailable, presenter::load)
        else -> PlanOfferCards(ui.products, ui.selected, presenter::select)
    }
}

@Composable
private fun Unavailable(reason: BillingUnavailable?, onRetry: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.paywall_prices_unavailable), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        Text(
            stringResource(reason?.explanationRes() ?: R.string.paywall_unavailable_body),
            style = PeeringText.caption,
            color = PeeringColors.muted,
        )
        QuietButton(onClick = onRetry) { Text(stringResource(R.string.paywall_try_again), style = PeeringText.footnoteMedium) }
    }
}

@Composable
private fun Footer(ui: PaywallUi) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        val note = when {
            ui.purchase == PurchaseState.FAILED -> R.string.paywall_purchase_failed to PeeringColors.danger
            ui.restore == RestoreState.NOTHING_TO_RESTORE -> R.string.paywall_restore_nothing to PeeringColors.muted
            ui.restore == RestoreState.FAILED -> R.string.paywall_restore_failed to PeeringColors.danger
            else -> null
        }
        if (note != null) Text(stringResource(note.first), style = PeeringText.caption, color = note.second, textAlign = TextAlign.Center)
        Text(
            stringResource(R.string.paywall_renewal_note),
            style = PeeringText.caption2,
            color = PeeringColors.tertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun BuyBar(ui: PaywallUi, presenter: PaywallPresenter, onDismiss: () -> Unit) {
    val uri = LocalUriHandler.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(PeeringColors.backdrop.copy(alpha = 0.92f))
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(start = 18.dp, end = 18.dp, top = 10.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val product = ui.products.firstOrNull { it.offer == ui.selected }
        if (ui.entitled) {
            WelcomePrimaryButton(stringResource(R.string.tour_start_using), onDismiss)
        } else if (product != null) {
            val purchasing = ui.purchase == PurchaseState.PURCHASING
            WelcomePrimaryButton(
                title = if (purchasing) stringResource(R.string.paywall_contacting_store) else product.buttonTitle(),
                onClick = presenter::buy,
                enabled = ui.canBuy,
            )
            if (ui.purchase == PurchaseState.AWAITING_APPROVAL) {
                Text(stringResource(R.string.paywall_purchase_pending), style = PeeringText.caption, color = PeeringColors.muted)
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally)) {
            BarLink(stringResource(R.string.paywall_restore), enabled = ui.restore != RestoreState.RESTORING, onClick = presenter::restore)
            BarLink(stringResource(R.string.tour_privacy)) { uri.openUri("https://getpeering.app/privacy") }
            BarLink(stringResource(R.string.tour_terms)) { uri.openUri("https://getpeering.app/terms") }
        }
        Text(
            stringResource(R.string.paywall_not_now),
            style = PeeringText.footnoteMedium,
            color = PeeringColors.muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().tappable(onDismiss).padding(vertical = 6.dp),
        )
    }
}

@Composable
private fun BarLink(title: String, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        title,
        style = PeeringText.caption,
        color = PeeringColors.muted,
        modifier = Modifier.tappable(onClick, enabled = enabled).padding(vertical = 4.dp),
    )
}
