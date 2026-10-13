package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** The tour's indicator: 6 point dots, the current one a 24 point capsule, sliding between. */
@Composable
fun PageDots(count: Int, current: Int, modifier: Modifier = Modifier) {
    Row(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { index ->
            val width = animateDpAsState(if (index == current) 24.dp else 6.dp, Motion.spring(), label = "dot")
            Box(
                Modifier
                    .height(6.dp)
                    .layout { measurable, constraints ->
                        val w = width.value.roundToPx()
                        val placeable = measurable.measure(Constraints.fixed(w, constraints.maxHeight.coerceAtMost(6.dp.roundToPx())))
                        layout(w, placeable.height) { placeable.place(0, 0) }
                    }
                    .background(if (index == current) PeeringColors.ink else Color.White.copy(alpha = 0.22f), CircleShape),
            )
        }
    }
}
