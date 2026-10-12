package pl.dmq.peering.feature.onboarding

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
import pl.dmq.peering.feature.paywall.PaywallUi
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.feature.paywall.RestoreState
import pl.dmq.peering.feature.paywall.explanationRes
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.size
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What the plans page puts under its heading: the free allowance and every paid offer the store listed, or why there are none. */
@Composable
internal fun PlansSection(ui: PaywallUi, freeChosen: Boolean, onChooseFree: () -> Unit, onChoose: (PlanOffer) -> Unit, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    when {
        ui.entitled -> Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(AppIcons.verifiedShield, null, tint = PeeringColors.accent, modifier = Modifier.size(40.dp))
            Text(stringResource(R.string.tour_on_pro_title), style = PeeringText.headline, color = PeeringColors.ink)
            Text(stringResource(R.string.tour_on_pro_body), style = PeeringText.caption, color = PeeringColors.muted, textAlign = TextAlign.Center)
        }
        ui.loading -> Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PeeringSpinner(color = PeeringColors.ink)
            Text(stringResource(R.string.tour_plans_loading), style = PeeringText.caption, color = PeeringColors.muted)
        }
        ui.products.isEmpty() -> Column(
            modifier.fillMaxWidth().tappable(onRetry),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PeeringSpinner(color = PeeringColors.ink)
            Text(
                stringResource(ui.unavailable?.explanationRes() ?: R.string.tour_plans_unreachable),
                style = PeeringText.caption,
                color = PeeringColors.muted,
                textAlign = TextAlign.Center,
            )
        }
        else -> PlanOfferCards(
            products = ui.products,
            selected = ui.selected,
            onChoose = onChoose,
            modifier = modifier.verticalScroll(rememberScrollState()),
            freeChosen = freeChosen,
            onChooseFree = onChooseFree,
        )
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
    Text(text, style = PeeringText.caption2.copy(fontSize = PeeringText.caption.fontSize), color = PeeringColors.muted, modifier = Modifier.tappable(onClick).padding(vertical = 4.dp))
}
