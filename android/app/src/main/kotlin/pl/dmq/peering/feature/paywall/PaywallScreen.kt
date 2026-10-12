package pl.dmq.peering.feature.paywall

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.billing.BillingUnavailable
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.kit.QuietButton

/** The plans: why the paywall opened, every offer the store lists, buying and restoring. */
@Composable
fun PaywallScreen(
    presenter: PaywallPresenter,
    reason: PaywallReason,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ReasonHeader(reason)
        Text(stringResource(R.string.paywall_free_promise), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        when {
            ui.entitled -> Text(stringResource(R.string.paywall_already_unlimited), style = MaterialTheme.typography.titleSmall, color = PeeringColors.added)
            ui.loading -> LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            ui.loadFailed || ui.products.isEmpty() -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.paywall_prices_unavailable), style = MaterialTheme.typography.titleSmall, color = PeeringColors.ink)
                ui.unavailable?.let { reason ->
                    Text(stringResource(reason.explanationRes()), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
                }
                Text(
                    stringResource(R.string.paywall_try_again),
                    style = MaterialTheme.typography.labelLarge,
                    color = PeeringColors.ink,
                    modifier = Modifier.clickable(onClick = presenter::load),
                )
            }
            else -> ui.products.forEach { product ->
                OfferRow(product, selected = product.offer == ui.selected, onClick = { presenter.select(product.offer) })
            }
        }
        if (!ui.entitled && ui.products.isNotEmpty()) {
            Button(
                onClick = presenter::buy,
                enabled = ui.canBuy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
            ) {
                Text(
                    stringResource(if (ui.purchase == PurchaseState.PURCHASING) R.string.paywall_contacting_store else R.string.paywall_buy),
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }
        PurchaseMessage(ui.purchase)
        RestoreRow(ui.restore, onRestore = presenter::restore)
        Text(stringResource(R.string.paywall_renewal_note), style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint)
        QuietButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.paywall_not_now))
        }
    }
}

@Composable
private fun ReasonHeader(reason: PaywallReason) {
    val freeLimit = remainingText(RemainingLabel.of(FREE_DAILY_RELAY_SECONDS))
    Text(
        stringResource(
            when (reason) {
                PaywallReason.Upgrade -> R.string.paywall_title_upgrade
                PaywallReason.RelayTimeSpent -> R.string.paywall_title_spent
                is PaywallReason.RunningLow -> R.string.paywall_title_low
            },
        ),
        style = MaterialTheme.typography.headlineSmall,
        color = PeeringColors.ink,
    )
    val detail = when (reason) {
        PaywallReason.Upgrade -> stringResource(R.string.paywall_detail_upgrade, freeLimit)
        PaywallReason.RelayTimeSpent -> stringResource(R.string.paywall_detail_spent, freeLimit)
        is PaywallReason.RunningLow -> stringResource(
            R.string.paywall_detail_low,
            remainingText(RemainingLabel.of(reason.remainingSeconds)),
        )
    }
    Text(detail, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
}

@Composable
private fun OfferRow(product: PaywallProduct, selected: Boolean, onClick: () -> Unit) {
    OutlinedPanel(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Text(
            stringResource(product.offer.titleRes()),
            style = MaterialTheme.typography.titleMedium,
            color = if (selected) PeeringColors.accent else PeeringColors.ink,
        )
        Text(product.displayPrice, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink)
        Text(stringResource(product.offer.detailRes()), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
    }
}

@StringRes
private fun PlanOffer.titleRes(): Int = when (this) {
    PlanOffer.MONTHLY -> R.string.paywall_offer_monthly
    PlanOffer.YEARLY -> R.string.paywall_offer_yearly
    PlanOffer.LIFETIME -> R.string.paywall_offer_lifetime
}

@StringRes
private fun PlanOffer.detailRes(): Int = when (this) {
    PlanOffer.MONTHLY -> R.string.paywall_offer_monthly_detail
    PlanOffer.YEARLY -> R.string.paywall_offer_yearly_detail
    PlanOffer.LIFETIME -> R.string.paywall_offer_lifetime_detail
}

@StringRes
private fun BillingUnavailable.explanationRes(): Int = when (this) {
    BillingUnavailable.NotSupported -> R.string.paywall_unavailable_not_supported
    BillingUnavailable.StoreUnreachable -> R.string.paywall_unavailable_unreachable
    BillingUnavailable.NotConfigured -> R.string.paywall_unavailable_not_configured
    is BillingUnavailable.Refused -> R.string.paywall_unavailable_refused
}

@Composable
private fun PurchaseMessage(state: PurchaseState) {
    val message = when (state) {
        PurchaseState.IDLE, PurchaseState.PURCHASING, PurchaseState.CANCELLED -> return
        PurchaseState.AWAITING_APPROVAL -> R.string.paywall_purchase_pending
        PurchaseState.PURCHASED -> R.string.paywall_purchase_done
        PurchaseState.FAILED -> R.string.paywall_purchase_failed
    }
    Text(stringResource(message), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
}

@Composable
private fun RestoreRow(state: RestoreState, onRestore: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            stringResource(R.string.paywall_restore),
            style = MaterialTheme.typography.labelLarge,
            color = PeeringColors.ink,
            modifier = Modifier.clickable(enabled = state != RestoreState.RESTORING, onClick = onRestore),
        )
        val message = when (state) {
            RestoreState.IDLE, RestoreState.RESTORING -> null
            RestoreState.RESTORED -> R.string.paywall_restore_done
            RestoreState.NOTHING_TO_RESTORE -> R.string.paywall_restore_nothing
            RestoreState.FAILED -> R.string.paywall_restore_failed
        }
        message?.let { Text(stringResource(it), style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted) }
    }
}
