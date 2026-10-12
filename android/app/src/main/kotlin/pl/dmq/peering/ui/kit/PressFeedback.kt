package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role

private const val PRESSED_SCALE = 0.97f
private const val PRESSED_ALPHA = 0.85f

/**
 * Shrinks to [scale] and dims to [alpha] while [source] is pressed. The amount is read in the layer block, so a press
 * redraws this element and recomposes nothing. Put it before any clip or background so they scale with it.
 */
fun Modifier.pressFeedback(source: InteractionSource, scale: Float = PRESSED_SCALE, alpha: Float = PRESSED_ALPHA): Modifier = composed {
    val pressed by source.collectIsPressedAsState()
    val amount = animateFloatAsState(if (pressed) 1f else 0f, Motion.fast(), label = "press")
    graphicsLayer {
        val held = amount.value
        val size = 1f - (1f - scale) * held
        scaleX = size
        scaleY = size
        this.alpha = 1f - (1f - alpha) * held
    }
}

/** A click with [pressFeedback] in place of a ripple, for fills a ripple would not show on. A null [onClick] leaves the element inert. */
fun Modifier.pressable(
    onClick: (() -> Unit)?,
    enabled: Boolean = true,
    role: Role = Role.Button,
    scale: Float = PRESSED_SCALE,
): Modifier = if (onClick == null) this else composed {
    val source = remember { MutableInteractionSource() }
    pressFeedback(source, scale).clickable(interactionSource = source, indication = null, enabled = enabled, role = role, onClick = onClick)
}
