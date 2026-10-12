package pl.dmq.peering.ui.theme

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp

private val rowFill = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.09f), Color.White.copy(alpha = 0.045f)))
private val rowEdge = BorderStroke(1.dp, Color.White.copy(alpha = 0.07f))

/** A row resting on a card: the one filled surface in the app. Pressing it scales it a hair and flashes the ripple. */
@Composable
fun PeeringRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    content: @Composable RowScope.() -> Unit,
) {
    val interactions = remember { MutableInteractionSource() }
    val pressed by interactions.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) PeeringMotion.PRESSED_SCALE else 1f, PeeringMotion.tap, label = "rowPress")
    val shape = MaterialTheme.shapes.small
    val base = modifier
        .graphicsLayer { scaleX = scale; scaleY = scale }
        .clip(shape)
        .background(rowFill)
        .border(rowEdge, shape)
    Row(
        modifier = (if (onClick != null) base.clickable(interactions, ripple(), onClick = onClick) else base)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}
