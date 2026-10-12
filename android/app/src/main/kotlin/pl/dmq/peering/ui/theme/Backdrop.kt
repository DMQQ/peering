package pl.dmq.peering.ui.theme

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp

private val backdropLightRadius = 460.dp

// One soft light from above over the near-black stage.
fun Modifier.peeringBackdrop(): Modifier = drawBehind {
    drawRect(PeeringColors.backdrop)
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(PeeringColors.ink.copy(alpha = 0.07f), PeeringColors.ink.copy(alpha = 0f)),
            center = Offset(size.width / 2f, 0f),
            radius = backdropLightRadius.toPx(),
        ),
    )
}
