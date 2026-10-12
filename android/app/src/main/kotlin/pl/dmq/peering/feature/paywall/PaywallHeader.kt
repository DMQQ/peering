package pl.dmq.peering.feature.paywall

import androidx.annotation.StringRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.billing.BillingUnavailable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** How much of the free day is left, as the share of the running-low bar that stays filled. */
internal fun runningLowFraction(remainingSeconds: Long, allowanceSeconds: Long): Float =
    if (allowanceSeconds <= 0) 0f else (remainingSeconds.toFloat() / allowanceSeconds).coerceIn(0f, 1f)

/** The pears mark, the reason as a 28 point serif title, one sentence under it, and the allowance bar when time is running low (PaywallView+Sections.swift, header). */
@Composable
internal fun PaywallHeader(reason: PaywallReason) {
    val freeLimit = remainingText(RemainingLabel.of(FREE_DAILY_RELAY_SECONDS))
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Image(painterResource(R.drawable.pears), null, Modifier.size(56.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(reason.titleRes()), style = PeeringText.display(size = 28f, tracking = -1f), color = PeeringColors.ink)
            Text(
                when (reason) {
                    PaywallReason.Upgrade -> stringResource(R.string.paywall_detail_upgrade, freeLimit)
                    PaywallReason.RelayTimeSpent -> stringResource(R.string.paywall_detail_spent)
                    is PaywallReason.RunningLow -> stringResource(R.string.paywall_detail_low, remainingText(RemainingLabel.of(reason.remainingSeconds)))
                },
                style = PeeringText.subheadline,
                color = PeeringColors.muted,
            )
            if (reason is PaywallReason.RunningLow) RemainingMeter(runningLowFraction(reason.remainingSeconds, FREE_DAILY_RELAY_SECONDS))
        }
    }
}

@Composable
private fun RemainingMeter(fraction: Float) {
    Box(Modifier.padding(top = 4.dp).fillMaxWidth().height(6.dp).clip(CircleShape).background(PeeringColors.ink.copy(alpha = 0.08f))) {
        Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().background(PeeringColors.caution))
    }
}

@StringRes
private fun PaywallReason.titleRes(): Int = when (this) {
    PaywallReason.Upgrade -> R.string.paywall_title_upgrade
    PaywallReason.RelayTimeSpent -> R.string.paywall_title_spent
    is PaywallReason.RunningLow -> R.string.paywall_title_low
}

@StringRes
internal fun BillingUnavailable.explanationRes(): Int = when (this) {
    BillingUnavailable.NotSupported -> R.string.paywall_unavailable_not_supported
    BillingUnavailable.StoreUnreachable -> R.string.paywall_unavailable_unreachable
    BillingUnavailable.NotConfigured -> R.string.paywall_unavailable_not_configured
    is BillingUnavailable.Refused -> R.string.paywall_unavailable_refused
}
