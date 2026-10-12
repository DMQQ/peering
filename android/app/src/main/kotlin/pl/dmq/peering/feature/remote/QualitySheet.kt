package pl.dmq.peering.feature.remote

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.QualityTier

/** The picture quality sheet: Auto, then the three fixed levels. The choice made here is the Settings default too. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QualitySheet(
    presenter: QualitySheetPresenter,
    onDismiss: () -> Unit,
) {
    val ui by presenter.ui.collectAsState()
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = stringResource(R.string.quality_title),
                style = MaterialTheme.typography.headlineSmall,
                color = PeeringColors.ink,
            )
            StreamQuality.entries.forEach { quality ->
                OutlinedPanel(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(MaterialTheme.shapes.large)
                        .clickable(role = Role.RadioButton) { presenter.choose(quality) },
                ) {
                    Text(
                        text = stringResource(quality.labelRes()),
                        style = MaterialTheme.typography.titleMedium,
                        color = if (quality == ui.selected) PeeringColors.ink else PeeringColors.muted,
                    )
                }
            }
            Text(
                text = stringResource(R.string.quality_explanation),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
            )
            if (ui.ceiling < QualityTier.HIGH) {
                Text(
                    text = stringResource(R.string.quality_relay_cap),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.caution,
                )
            }
            if (ui.saveFailed) {
                Text(
                    text = stringResource(R.string.quality_save_failed),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.danger,
                )
            }
        }
    }
}

private fun StreamQuality.labelRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.quality_auto
    StreamQuality.Low -> R.string.quality_low
    StreamQuality.Medium -> R.string.quality_medium
    StreamQuality.High -> R.string.quality_high
}
