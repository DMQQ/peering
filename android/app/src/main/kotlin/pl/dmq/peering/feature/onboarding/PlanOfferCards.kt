package pl.dmq.peering.feature.onboarding

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.paywall.FREE_DAILY_RELAY_SECONDS
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PlanOffer

/**
 * Free (when [onChooseFree] is given), then Pro and Lifetime as one-line rows, 10 points apart (PlanOfferCards.swift).
 * [freeChosen] selects the Free row, otherwise [selected] picks a paid one.
 */
@Composable
internal fun PlanOfferCards(
    products: List<PaywallProduct>,
    selected: PlanOffer?,
    onChoose: (PlanOffer) -> Unit,
    modifier: Modifier = Modifier,
    freeChosen: Boolean = false,
    onChooseFree: (() -> Unit)? = null,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (onChooseFree != null) {
            PlanCard(
                title = stringResource(R.string.tour_plan_free),
                detail = stringResource(R.string.tour_plan_free_detail, (FREE_DAILY_RELAY_SECONDS / 60).toInt()),
                selected = freeChosen,
                onClick = onChooseFree,
            )
        }
        products.forEach { product ->
            PlanCard(
                title = stringResource(product.offer.titleRes()),
                detail = stringResource(product.offer.noteRes()),
                selected = !freeChosen && product.offer == selected,
                onClick = { onChoose(product.offer) },
                price = product.displayPrice,
                priceCaption = stringResource(product.offer.captionRes()),
                badge = if (product.offer == PlanOffer.LIFETIME) stringResource(R.string.tour_plan_best_value) else null,
            )
        }
    }
}

@StringRes
internal fun PlanOffer.titleRes(): Int = when (this) {
    PlanOffer.MONTHLY -> R.string.plan_pro
    PlanOffer.YEARLY -> R.string.plan_pro_yearly
    PlanOffer.LIFETIME -> R.string.paywall_offer_lifetime
}

@StringRes
private fun PlanOffer.noteRes(): Int = when (this) {
    PlanOffer.MONTHLY, PlanOffer.YEARLY -> R.string.plan_pro_note
    PlanOffer.LIFETIME -> R.string.plan_lifetime_note
}

@StringRes
private fun PlanOffer.captionRes(): Int = when (this) {
    PlanOffer.MONTHLY -> R.string.tour_plan_per_month
    PlanOffer.YEARLY -> R.string.tour_plan_per_year
    PlanOffer.LIFETIME -> R.string.tour_plan_one_time
}

/** The buy button's label: shorter only, a longer one wraps on a small phone (PlanOffer.swift, buttonTitle). */
@Composable
internal fun PaywallProduct.buttonTitle(): String = when (offer) {
    PlanOffer.MONTHLY -> stringResource(R.string.plan_button_monthly, displayPrice)
    PlanOffer.YEARLY -> stringResource(R.string.plan_button_yearly, displayPrice)
    PlanOffer.LIFETIME -> stringResource(R.string.plan_button_lifetime, displayPrice)
}
