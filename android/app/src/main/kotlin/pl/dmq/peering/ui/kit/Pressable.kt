package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.ui.theme.PeeringMotion

/**
 * The iPhone's press: no ripple, the control shrinks to [scale] and dims a little, then returns on the settle spring.
 * [dim] is the opacity at rest minus the press loss.
 */
fun Modifier.pressable(
    onClick: (() -> Unit)?,
    enabled: Boolean = true,
    scale: Float = 0.98f,
    dim: Float = 1f,
    role: Role = Role.Button,
): Modifier = composed {
    if (onClick == null) return@composed this
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed) scale else 1f,
        animationSpec = if (pressed) tween(durationMillis = 120) else PeeringMotion.settle,
        label = "pressScale",
    )
    val pressAlpha by animateFloatAsState(if (pressed) dim else 1f, tween(durationMillis = 120), label = "pressAlpha")
    this
        .graphicsLayer { scaleX = pressScale; scaleY = pressScale; alpha = pressAlpha }
        .clickable(interactionSource = source, indication = null, enabled = enabled, role = role, onClick = onClick)
}
