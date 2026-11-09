package pl.dmq.peering.feature.agents.routines

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlIcon
import pl.dmq.peering.ui.kit.hubCardSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** The way onto the routines list from the Agents page. [count] is how many the computer holds, null until it has listed them. */
@Composable
fun RoutinesEntry(count: Int?, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().hubCardSurface(peeringShapes.large).tappable(onOpen).padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ControlIcon(AppIcons.clockAlert)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.routines_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            Text(
                if (count == null || count == 0) stringResource(R.string.routines_entry_empty) else routineCountText(count),
                style = PeeringText.caption,
                color = PeeringColors.muted,
            )
        }
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(18.dp))
    }
}
