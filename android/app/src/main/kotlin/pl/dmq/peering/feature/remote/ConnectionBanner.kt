package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.chipSurface
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** Shown while the link is being put back, so a frozen picture is never left unexplained. */
@Composable
fun ConnectionBanner(hostName: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .semantics { liveRegion = LiveRegionMode.Polite }
            .chipSurface(peeringShapes.large)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = PeeringColors.caution)
        Column {
            Text(
                text = stringResource(R.string.remote_reconnecting, hostName),
                style = MaterialTheme.typography.titleSmall,
                color = PeeringColors.ink,
            )
            Text(
                text = stringResource(R.string.remote_reconnecting_detail),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
            )
        }
    }
}
