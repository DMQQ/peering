package pl.dmq.peering.feature.onboarding

import android.util.Log
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.feature.paywall.PaywallPresenter
import pl.dmq.peering.feature.paywall.PaywallUi
import pl.dmq.peering.feature.paywall.PurchaseState
import pl.dmq.peering.ui.kit.PageDots
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.rememberSheen
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect

private const val TAG = "PeeringTour"

private val wordsHeight = 222.dp

/**
 * The eight pages. The words swipe with the pager; the device they are about is drawn once above it and changes
 * underneath, so a page turn reads as one phone showing something else.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun TourScreen(
    presenter: OnboardingPresenter,
    plans: PaywallPresenter,
    onSkip: () -> Unit,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pager = rememberPagerState(initialPage = presenter.ui.value.step.pageIndex ?: 0, pageCount = { tourPages.size })
    val scope = rememberCoroutineScope()
    val paywall by plans.ui.collectAsState()
    var freeChosen by remember { mutableStateOf(false) }
    var stageHeight by remember { mutableIntStateOf(0) }
    LaunchedEffect(pager) {
        snapshotFlow { pager.currentPage }.collect { presenter.goTo(tourPages[it].step) }
    }
    LaunchedEffect(paywall.purchase) { if (paywall.purchase == PurchaseState.PURCHASED) onFinished() }
    val current = tourPages[pager.currentPage]
    val onPlans = current.content is TourContent.Plans

    Box(modifier.fillMaxSize().peeringBackdrop()) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
            HorizontalPager(pager, Modifier.weight(1f)) { index ->
                val page = tourPages[index]
                if (page.content is TourContent.Plans) {
                    PlansPage(page, paywall, freeChosen, plans, { freeChosen = it })
                } else {
                    Column(Modifier.fillMaxSize().padding(horizontal = 22.dp).padding(bottom = 6.dp)) {
                        Spacer(
                            Modifier.weight(1f).fillMaxWidth().onSizeChanged { if (index == pager.currentPage) stageHeight = it.height },
                        )
                        Spacer(Modifier.height(18.dp))
                        Words(page, isCurrent = index == pager.currentPage)
                    }
                }
            }
            PageDots(tourPages.size, pager.currentPage, Modifier.align(Alignment.CenterHorizontally).padding(top = 4.dp, bottom = 20.dp))
            Box(Modifier.windowInsetsPadding(WindowInsets.navigationBars).padding(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 18.dp)) {
                PrimaryButton(
                    title = buttonTitle(current, paywall, freeChosen),
                    enabled = !(onPlans && paywall.purchase == PurchaseState.PURCHASING),
                    onClick = {
                        val action = plansAction(onPlans, freeChosen, paywall.entitled, paywall.products.isNotEmpty())
                        Log.i(TAG, "tour button on page ${pager.currentPage}: $action")
                        when (action) {
                            PlansAction.Next -> scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                            PlansAction.Finish -> onFinished()
                            PlansAction.Buy -> plans.buy()
                        }
                    },
                )
            }
        }
        if (!onPlans) {
            val stageDp = with(LocalDensity.current) { stageHeight.toDp() }
            TourStage(
                current,
                Modifier
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .padding(horizontal = 22.dp)
                    .height(stageDp),
            )
            SkipButton(onSkip, Modifier.align(Alignment.TopEnd))
        }
    }
}

@Composable
private fun buttonTitle(page: TourPage, paywall: PaywallUi, freeChosen: Boolean): String {
    if (page.content !is TourContent.Plans) return stringResource(R.string.tour_next)
    if (paywall.entitled) return stringResource(R.string.tour_get_started)
    val product = paywall.products.firstOrNull { it.offer == paywall.selected }
    return when {
        freeChosen || product == null -> stringResource(R.string.tour_start_using)
        paywall.purchase == PurchaseState.PURCHASING -> stringResource(R.string.paywall_contacting_store)
        else -> stringResource(R.string.tour_continue_with, planName(product.offer), product.displayPrice)
    }
}

@Composable
private fun planName(offer: pl.dmq.peering.feature.paywall.PlanOffer): String = stringResource(
    when (offer) {
        pl.dmq.peering.feature.paywall.PlanOffer.MONTHLY -> R.string.paywall_offer_monthly
        pl.dmq.peering.feature.paywall.PlanOffer.YEARLY -> R.string.paywall_offer_yearly
        pl.dmq.peering.feature.paywall.PlanOffer.LIFETIME -> R.string.paywall_offer_lifetime
    },
)

@Composable
private fun Words(page: TourPage, isCurrent: Boolean) {
    Column(Modifier.fillMaxWidth().heightIn(min = wordsHeight), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Heading(stringResource(page.title), isCurrent)
        Text(stringResource(page.body), style = PeeringText.subheadline.copy(letterSpacing = (-0.2).sp), color = PeeringColors.muted)
        if (page.showsDownload) DownloadLink()
    }
}

@Composable
internal fun Heading(title: String, lit: Boolean) {
    Text(title, style = PeeringText.display(size = 34f, tracking = -1f, lineHeight = 38f).copy(brush = rememberSheen(lit)))
}

@Composable
private fun PlansPage(page: TourPage, paywall: PaywallUi, freeChosen: Boolean, plans: PaywallPresenter, setFree: (Boolean) -> Unit) {
    Column(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, top = 14.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Heading(stringResource(page.title), lit = true)
        PlansHero(Modifier.weight(1f).fillMaxWidth().heightIn(min = 120.dp))
        PlansSection(
            ui = paywall,
            freeChosen = freeChosen,
            onChooseFree = { setFree(true) },
            onChoose = { setFree(false); plans.select(it) },
            onRetry = plans::load,
            modifier = Modifier.heightIn(max = 330.dp),
        )
        LegalLinks(paywall.restore, plans::restore)
    }
}
