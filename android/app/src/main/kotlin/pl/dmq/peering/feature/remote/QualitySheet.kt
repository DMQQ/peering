package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ChoiceRow
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.QualityTier

/** The picture quality sheet: Auto, then the three fixed levels, each saying what it costs. The choice is the Settings default too. */
@Composable
fun QualitySheet(
    presenter: QualitySheetPresenter,
    onDismiss: () -> Unit,
) {
    val ui by presenter.ui.collectAsState()
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.quality_title)) {
        StreamQuality.entries.forEach { quality ->
            ChoiceRow(
                icon = quality.icon(),
                title = stringResource(quality.labelRes()),
                description = stringResource(quality.descriptionRes()),
                selected = quality == ui.selected,
                role = Role.RadioButton,
                onClick = { presenter.choose(quality) },
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

private fun StreamQuality.icon(): ImageVector = when (this) {
    StreamQuality.Auto -> AppIcons.sparkles
    StreamQuality.Low -> AppIcons.signalLow
    StreamQuality.Medium -> AppIcons.signalMedium
    StreamQuality.High -> AppIcons.signalHigh
}

private fun StreamQuality.descriptionRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.quality_auto_description
    StreamQuality.Low -> R.string.quality_low_description
    StreamQuality.Medium -> R.string.quality_medium_description
    StreamQuality.High -> R.string.quality_high_description
}

private fun StreamQuality.labelRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.quality_auto
    StreamQuality.Low -> R.string.quality_low
    StreamQuality.Medium -> R.string.quality_medium
    StreamQuality.High -> R.string.quality_high
}
