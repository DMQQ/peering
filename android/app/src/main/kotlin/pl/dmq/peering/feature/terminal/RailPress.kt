package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.ui.kit.pressFeedback

/** The iPhone's button feel: the control shrinks to [scale] and dims while held, instead of a ripple. */
@Composable
fun Modifier.railPress(onClick: () -> Unit, enabled: Boolean = true, scale: Float = 0.9f): Modifier {
    val source = remember { MutableInteractionSource() }
    return this
        .pressFeedback(source, scale = scale)
        .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
}
