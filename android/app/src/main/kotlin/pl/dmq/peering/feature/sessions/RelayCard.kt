package pl.dmq.peering.feature.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.paywall.RelayAllowance
import pl.dmq.peering.feature.paywall.RemainingLabel
import pl.dmq.peering.feature.paywall.remainingText
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.SectionLabel

/** Today's free relay time: the figure, a meter, and the way to more of it once it runs low. */
@Composable
internal fun RelayCard(allowance: RelayAllowance, meter: RelayMeter, onUpgrade: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().cardBackground().tappable(onUpgrade).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        SectionLabel(stringResource(R.string.sessions_relay), AppIcons.network)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.sessions_relay_free), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, modifier = Modifier.weight(1f))
                Text(
                    stringResource(R.string.sessions_relay_left, remainingText(RemainingLabel.of(allowance.remainingSeconds))),
                    style = PeeringText.captionSemibold,
                    color = if (meter.low) PeeringColors.caution else PeeringColors.muted,
                )
            }
            Meter(meter)
            Text(stringResource(R.string.sessions_relay_period), style = PeeringText.caption, color = PeeringColors.muted, textAlign = TextAlign.End, modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.sessions_relay_note), style = PeeringText.caption2, color = PeeringColors.tertiary)
            if (meter.low) {
                InkButton(onClick = onUpgrade, modifier = Modifier.fillMaxWidth().padding(top = 2.dp)) {
                    Text(stringResource(R.string.sessions_upgrade))
                    Icon(AppIcons.arrowForward, contentDescription = null, modifier = Modifier.padding(start = 7.dp).size(16.dp))
                }
            }
        }
    }
}

@Composable
private fun Meter(meter: RelayMeter) {
    Box(Modifier.fillMaxWidth().height(6.dp).clip(PillShape).background(PeeringColors.ink.copy(alpha = 0.08f))) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(meter.remainingFraction)
                .clip(PillShape)
                .background(if (meter.low) PeeringColors.caution else PeeringColors.accent),
        )
    }
}
