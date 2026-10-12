package pl.dmq.peering.ui.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun inkButtonColors(): ButtonColors = ButtonDefaults.buttonColors(
    containerColor = PeeringColors.ink,
    contentColor = PeeringColors.onInk,
    disabledContainerColor = PeeringColors.surface,
    disabledContentColor = PeeringColors.faint,
)

/** The one filled control on a screen: white with a black label, as the Mac and iPhone draw it. */
@Composable
fun InkButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) {
    Button(onClick = onClick, modifier = modifier.height(48.dp), enabled = enabled, colors = inkButtonColors(), content = content)
}

/** A quiet capsule beside the ink button: outlined, white label. */
@Composable
fun QuietButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(48.dp),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = PeeringColors.ink, containerColor = Color.Transparent),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.18f)),
        content = content,
    )
}
