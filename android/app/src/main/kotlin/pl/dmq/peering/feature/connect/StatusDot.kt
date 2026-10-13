package pl.dmq.peering.feature.connect

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

private val presenceGreen = Color(0xFF34C759)

/** Filled green for a computer known to be up, hollow for one not seen: a grey filled dot would mean both off and unchecked. Ringed in the backdrop so it cuts into its tile. */
@Composable
internal fun StatusDot(up: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier
            .offset(2.dp, 2.dp)
            .size(9.dp)
            .background(if (up) presenceGreen else Color.Transparent, CircleShape)
            .border(1.5.dp, if (up) PeeringColors.backdrop else Color.White.copy(alpha = 0.35f), CircleShape),
    )
}
