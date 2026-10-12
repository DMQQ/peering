package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** The tour's indicator: 6 point dots, the current one a 24 point capsule, springing between. */
@Composable
fun PageDots(count: Int, current: Int, modifier: Modifier = Modifier) {
    Row(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { index ->
            val width by animateDpAsState(if (index == current) 24.dp else 6.dp, spring(dampingRatio = 0.8f, stiffness = 340f), label = "dot")
            Row(
                Modifier
                    .width(width)
                    .height(6.dp)
                    .background(if (index == current) PeeringColors.ink else Color.White.copy(alpha = 0.22f), CircleShape),
            ) {}
        }
    }
}
