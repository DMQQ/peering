package pl.dmq.peering.feature.onboarding

import pl.dmq.peering.ui.kit.DepthTransition
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.paywall.PaywallBilling
import pl.dmq.peering.feature.paywall.PaywallPresenter

/**
 * The first run: the landing, then the tour that ends on the plans. [onFinished] runs once the user finishes or skips,
 * after the store has recorded it; the caller then shows the rest of the app.
 */
@Composable
fun OnboardingRoute(
    store: FirstRunStore,
    billing: PaywallBilling,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    startAt: OnboardingStep = OnboardingStep.LANDING,
) {
    val presenter = remember(store) { OnboardingPresenter(store, startAt) }
    val scope = rememberCoroutineScope()
    val plans = remember(billing) { PaywallPresenter(billing, scope) }
    val ui by presenter.ui.collectAsState()
    LaunchedEffect(ui.completed) {
        if (ui.completed) onFinished()
    }
    DepthTransition(
        state = ui.step == OnboardingStep.LANDING,
        depth = { onLanding -> if (onLanding) 0 else 1 },
        modifier = modifier,
        label = "welcome",
    ) { onLanding ->
        if (onLanding) {
            WelcomeLanding(onStart = presenter::next, onSkip = presenter::skip)
        } else {
            TourScreen(presenter = presenter, plans = plans, onSkip = presenter::skip, onFinished = presenter::finish)
        }
    }
}
