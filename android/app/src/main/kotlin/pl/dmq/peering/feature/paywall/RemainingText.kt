package pl.dmq.peering.feature.paywall

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R

@Composable
fun remainingText(label: RemainingLabel): String = when (label) {
    RemainingLabel.None -> stringResource(R.string.remaining_none)
    RemainingLabel.UnderAMinute -> stringResource(R.string.remaining_under_minute)
    is RemainingLabel.Minutes -> pluralStringResource(R.plurals.remaining_minutes, label.minutes, label.minutes)
    is RemainingLabel.HoursAndMinutes -> stringResource(R.string.remaining_hours_minutes, label.hours, label.minutes)
}
