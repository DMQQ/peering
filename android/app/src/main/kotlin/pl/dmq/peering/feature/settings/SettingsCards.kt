package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** A settings card: an outlined panel with a heading in the muted label style. */
@Composable
internal fun SettingsCard(
    heading: String,
    content: @Composable () -> Unit,
) {
    OutlinedPanel(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = heading,
            style = MaterialTheme.typography.titleSmall,
            color = PeeringColors.muted,
        )
        Spacer(Modifier.height(12.dp))
        content()
    }
}

@Composable
internal fun StreamQualityCard(current: StreamQuality, onChoose: (StreamQuality) -> Unit) {
    SettingsCard(heading = stringResource(R.string.settings_quality_heading)) {
        StreamQuality.entries.forEach { quality ->
            val selected = quality == current
            PeeringListItem(
                headline = stringResource(quality.labelRes()),
                onClick = { onChoose(quality) },
                role = Role.RadioButton,
                leading = {
                    RadioButton(
                        selected = selected,
                        onClick = null,
                        colors = RadioButtonDefaults.colors(
                            selectedColor = PeeringColors.accent,
                            unselectedColor = PeeringColors.faint,
                        ),
                    )
                },
            )
        }
    }
}
