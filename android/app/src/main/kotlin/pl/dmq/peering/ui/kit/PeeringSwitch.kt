package pl.dmq.peering.ui.kit

import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import pl.dmq.peering.ui.theme.PeeringColors

/** Material's switch in the palette: the single blue when on, a grey track when off. */
@Composable
fun PeeringSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = PeeringColors.ink,
            checkedTrackColor = PeeringColors.accent,
            checkedBorderColor = PeeringColors.accent,
            uncheckedThumbColor = PeeringColors.muted,
            uncheckedTrackColor = PeeringColors.switchOffTrack,
            uncheckedBorderColor = PeeringColors.switchOffTrack,
        ),
    )
}
