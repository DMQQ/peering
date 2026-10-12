package pl.dmq.peering.feature.remote

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** An outlined chip naming the route the session is on: the local network, the relay, or the direct path. */
@Composable
fun PathBadge(path: SessionRecord.Path, modifier: Modifier = Modifier) {
    val description = stringResource(path.descriptionRes())
    Text(
        text = stringResource(path.labelRes()),
        style = MaterialTheme.typography.labelMedium,
        color = PeeringColors.ink,
        modifier = modifier
            .semantics { contentDescription = description }
            .border(1.dp, PeeringColors.faint, peeringShapes.extraSmall)
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

internal fun SessionRecord.Path.labelRes(): Int = when (this) {
    SessionRecord.Path.LAN -> R.string.overlay_path_lan
    SessionRecord.Path.RELAY -> R.string.overlay_path_relay
    SessionRecord.Path.DIRECT -> R.string.overlay_path_direct
}

private fun SessionRecord.Path.descriptionRes(): Int = when (this) {
    SessionRecord.Path.LAN -> R.string.overlay_path_lan_description
    SessionRecord.Path.RELAY -> R.string.overlay_path_relay_description
    SessionRecord.Path.DIRECT -> R.string.overlay_path_direct_description
}
