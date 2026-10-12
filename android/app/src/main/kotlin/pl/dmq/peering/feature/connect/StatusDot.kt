package pl.dmq.peering.feature.connect

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** Blue only for the connected host; ink for one that is up; a hollow ring for one not seen. */
@Composable
internal fun StatusDot(status: HostStatus) {
    val base = Modifier.size(9.dp)
    when (status) {
        HostStatus.Connected -> Box(base.background(PeeringColors.accent, CircleShape))
        HostStatus.Online -> Box(base.background(PeeringColors.ink, CircleShape))
        HostStatus.Unknown -> Box(base.border(1.5.dp, PeeringColors.faint, CircleShape))
    }
}
