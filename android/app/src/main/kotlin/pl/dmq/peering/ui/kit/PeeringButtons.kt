package pl.dmq.peering.ui.kit

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

private val inkColors @Composable get() = ButtonDefaults.buttonColors(
    containerColor = PeeringColors.ink,
    contentColor = PeeringColors.onInk,
    disabledContainerColor = PeeringColors.containerHighest,
    disabledContentColor = PeeringColors.faint,
)

/** The one filled control on a screen: Material's filled button, white with a black label, full width. */
@Composable
fun PrimaryButton(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Button(onClick = onClick, modifier = modifier.fillMaxWidth(), enabled = enabled, colors = inkColors) { Text(title) }
}

/** A filled button with arbitrary content, for a state where the label is not just text. */
@Composable
fun InkButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) {
    Button(onClick = onClick, modifier = modifier, enabled = enabled, colors = inkColors, content = content)
}

/** The quieter second action: Material's outlined button. */
@Composable
fun QuietButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        colors = ButtonDefaults.outlinedButtonColors(contentColor = PeeringColors.ink),
        border = BorderStroke(1.dp, PeeringColors.outline),
        content = content,
    )
}

/** A middle weight between filled and outlined: Material's tonal button. */
@Composable
fun TonalButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier,
        colors = ButtonDefaults.filledTonalButtonColors(containerColor = PeeringColors.containerHighest, contentColor = PeeringColors.ink),
        content = content,
    )
}

/** The lowest emphasis: Material's text button in the single blue. */
@Composable
fun LinkButton(title: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(onClick = onClick, modifier = modifier, colors = ButtonDefaults.textButtonColors(contentColor = PeeringColors.accent)) { Text(title) }
}
