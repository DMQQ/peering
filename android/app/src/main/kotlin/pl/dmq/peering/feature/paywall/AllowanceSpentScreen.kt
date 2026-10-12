package pl.dmq.peering.feature.paywall

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.kit.QuietButton

/** Shown when the relay ends a session because the day's free time is gone. The Mac's own network still works. */
@Composable
fun AllowanceSpentScreen(
    ui: AllowanceUi,
    onSeePlans: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val free = !ui.paid
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(if (free) R.string.allowance_title_spent else R.string.allowance_title_stopped),
            style = MaterialTheme.typography.headlineSmall,
            color = PeeringColors.ink,
        )
        Text(
            when {
                !free -> stringResource(R.string.allowance_detail_paid)
                else -> stringResource(R.string.allowance_detail_free, remainingText(ui.dailyLimit))
            },
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
        )
        if (free && ui.remaining != RemainingLabel.None) {
            Text(
                stringResource(R.string.allowance_left_today, remainingText(ui.remaining)),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
            )
        }
        Button(
            onClick = onSeePlans,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
        ) {
            Text(stringResource(R.string.allowance_see_plans), style = MaterialTheme.typography.labelLarge)
        }
        QuietButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.paywall_not_now))
        }
    }
}
