package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.QualityTier

/** The picture quality sheet: Auto, then the three fixed levels. The choice made here is the Settings default too. */
@Composable
fun QualitySheet(
    presenter: QualitySheetPresenter,
    onDismiss: () -> Unit,
) {
    val ui by presenter.ui.collectAsState()
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.quality_title)) {
        StreamQuality.entries.forEach { quality ->
            PeeringListItem(
                headline = stringResource(quality.labelRes()),
                onClick = { presenter.choose(quality) },
                role = Role.RadioButton,
                bleed = false,
                leading = {
                    RadioButton(
                        selected = quality == ui.selected,
                        onClick = null,
                        colors = RadioButtonDefaults.colors(selectedColor = PeeringColors.accent, unselectedColor = PeeringColors.faint),
                    )
                },
            )
        }
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
