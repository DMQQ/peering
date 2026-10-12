package pl.dmq.peering.feature.paywall

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.WelcomePrimaryButton
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop

/** Shown when the relay ends a session because the day's free time is gone (AllowanceSpentView.swift). The computer's own network still works. */
@Composable
fun AllowanceSpentScreen(
    ui: AllowanceUi,
    onSeePlans: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val free = !ui.paid
    Column(
        modifier = modifier
            .fillMaxSize()
            .peeringBackdrop()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 18.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(AppIcons.clockAlert, null, tint = PeeringColors.ink, modifier = Modifier.size(46.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(if (free) R.string.allowance_title_spent else R.string.allowance_title_stopped),
                style = PeeringText.display(size = 28f, tracking = -1f),
                color = PeeringColors.ink,
            )
            Text(
                if (free) stringResource(R.string.allowance_detail_free, remainingText(ui.dailyLimit)) else stringResource(R.string.allowance_detail_paid),
                style = PeeringText.subheadline,
                color = PeeringColors.muted,
            )
        }
        WelcomePrimaryButton(stringResource(R.string.allowance_see_plans), onSeePlans, Modifier.padding(top = 4.dp))
        Text(
            stringResource(R.string.paywall_not_now),
            style = PeeringText.footnoteMedium,
            color = PeeringColors.muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().tappable(onDismiss).padding(vertical = 6.dp),
        )
    }
}
