package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import pl.dmq.peering.feature.paywall.PaywallProduct
import pl.dmq.peering.feature.paywall.PaywallUi
import pl.dmq.peering.feature.paywall.PlanOffer
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.theme.peeringBackdrop

private fun ignore() = Unit

@Suppress("UNUSED_PARAMETER")
private fun ignore(offer: PlanOffer) = Unit

private val offers = listOf(
    PaywallProduct(PlanOffer.MONTHLY, "monthly", "$4.99"),
    PaywallProduct(PlanOffer.YEARLY, "yearly", "$29.99"),
    PaywallProduct(PlanOffer.LIFETIME, "lifetime", "$59.99"),
)

@Composable
private fun Frame(ui: PaywallUi, freeChosen: Boolean) {
    PeeringTheme {
        Column(Modifier.peeringBackdrop().padding(22.dp)) {
            PlansSection(ui, freeChosen, onChooseFree = ::ignore, onChoose = ::ignore, onRetry = ::ignore)
        }
    }
}

@Preview(name = "Plans, a paid plan chosen", showBackground = true, heightDp = 640)
@Composable
private fun PlansPaidPreview() = Frame(PaywallUi(products = offers, selected = PlanOffer.YEARLY), freeChosen = false)

@Preview(name = "Plans, Free chosen", showBackground = true, heightDp = 640)
@Composable
private fun PlansFreePreview() = Frame(PaywallUi(products = offers, selected = PlanOffer.YEARLY), freeChosen = true)

@Preview(name = "Plans, store unreachable", showBackground = true, heightDp = 400)
@Composable
private fun PlansUnreachablePreview() = Frame(PaywallUi(loading = false), freeChosen = true)

@Preview(name = "Plans, loading", showBackground = true, heightDp = 300)
@Composable
private fun PlansLoadingPreview() = Frame(PaywallUi(loading = true), freeChosen = false)
