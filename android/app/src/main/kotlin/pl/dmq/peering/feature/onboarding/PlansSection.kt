package pl.dmq.peering.feature.onboarding

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.paywall.FREE_DAILY_RELAY_SECONDS
import pl.dmq.peering.feature.paywall.PaywallUi
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.feature.paywall.RestoreState
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.Symbols
import pl.dmq.peering.ui.kit.pressable
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.size
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What the plans page puts under its heading: the free allowance and every paid offer the store listed, or why there are none. */
@Composable
internal fun PlansSection(ui: PaywallUi, freeChosen: Boolean, onChooseFree: () -> Unit, onChoose: (PlanOffer) -> Unit, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    when {
        ui.entitled -> Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Symbols.checkmarkShield, null, tint = PeeringColors.accent, modifier = Modifier.size(40.dp))
            Text(stringResource(R.string.tour_on_pro_title), style = PeeringText.headline, color = PeeringColors.ink)
            Text(stringResource(R.string.tour_on_pro_body), style = PeeringText.caption, color = PeeringColors.muted, textAlign = TextAlign.Center)
        }
        ui.loading -> Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PeeringSpinner(color = PeeringColors.ink)
            Text(stringResource(R.string.tour_plans_loading), style = PeeringText.caption, color = PeeringColors.muted)
        }
        ui.products.isEmpty() -> Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PlanCard(
                title = stringResource(R.string.tour_plan_free),
                detail = stringResource(R.string.tour_plan_free_detail, (FREE_DAILY_RELAY_SECONDS / 60).toInt()),
                selected = true,
                onClick = onChooseFree,
            )
            Text(
                stringResource(R.string.tour_plans_unreachable),
                style = PeeringText.caption,
                color = PeeringColors.muted,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().pressable(onRetry),
            )
        }
        else -> Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PlanCard(
                title = stringResource(R.string.tour_plan_free),
                detail = stringResource(R.string.tour_plan_free_detail, (FREE_DAILY_RELAY_SECONDS / 60).toInt()),
                selected = freeChosen,
                onClick = onChooseFree,
            )
            ui.products.forEach { product ->
                PlanCard(
                    title = stringResource(product.offer.titleRes()),
                    detail = stringResource(product.offer.detailRes()),
                    selected = !freeChosen && product.offer == ui.selected,
                    onClick = { onChoose(product.offer) },
                    price = product.displayPrice,
                    priceCaption = stringResource(product.offer.captionRes()),
                    badge = if (product.offer == PlanOffer.LIFETIME) stringResource(R.string.tour_plan_best_value) else null,
                )
            }
        }
    }
}

/** Restore, privacy and terms: a screen that shows prices carries all three, whether or not anything is bought on it. */
@Composable
internal fun LegalLinks(restore: RestoreState, onRestore: () -> Unit, modifier: Modifier = Modifier) {
    val uri = LocalUriHandler.current
    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            LinkText(stringResource(R.string.paywall_restore), onRestore)
            LinkText(stringResource(R.string.tour_privacy)) { uri.openUri("https://getpeering.app/privacy") }
            LinkText(stringResource(R.string.tour_terms)) { uri.openUri("https://getpeering.app/terms") }
        }
        val note = when (restore) {
            RestoreState.RESTORED -> R.string.paywall_restore_done
            RestoreState.NOTHING_TO_RESTORE -> R.string.paywall_restore_nothing
            RestoreState.FAILED -> R.string.paywall_restore_failed
            RestoreState.IDLE, RestoreState.RESTORING -> null
        }
        if (note != null) Text(stringResource(note), style = PeeringText.caption2, color = if (restore == RestoreState.FAILED) PeeringColors.danger else PeeringColors.muted, textAlign = TextAlign.Center)
    }
}

@Composable
private fun LinkText(text: String, onClick: () -> Unit) {
    Text(text, style = PeeringText.caption2.copy(fontSize = PeeringText.caption.fontSize), color = PeeringColors.muted, modifier = Modifier.pressable(onClick).padding(vertical = 4.dp))
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
private fun PlanOffer.captionRes(): Int = when (this) {
    PlanOffer.MONTHLY -> R.string.tour_plan_per_month
    PlanOffer.YEARLY -> R.string.tour_plan_per_year
    PlanOffer.LIFETIME -> R.string.tour_plan_one_time
}
