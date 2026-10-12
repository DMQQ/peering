package pl.dmq.peering.feature.terminal

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role

private const val PRESS_MILLIS = 120
private const val PRESSED_ALPHA = 0.6f

/**
 * The iPhone's button feel: the control shrinks to [scale] and fades to 60 percent while held, instead of a ripple.
 * The pressed amount is read inside the layer block, so a press redraws the key and recomposes nothing around it.
 */
@Composable
fun Modifier.railPress(onClick: () -> Unit, enabled: Boolean = true, scale: Float = 0.9f): Modifier {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val amount = animateFloatAsState(if (pressed) 1f else 0f, tween(PRESS_MILLIS), label = "railPress")
    return this
        .graphicsLayer {
            val held = amount.value
            val size = 1f - (1f - scale) * held
            scaleX = size
            scaleY = size
            alpha = 1f - (1f - PRESSED_ALPHA) * held
        }
        .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
}
