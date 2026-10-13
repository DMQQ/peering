package pl.dmq.peering.ui.kit

import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.VisualTransformation
import pl.dmq.peering.ui.theme.PeeringColors

/** Material's outlined field in the palette: a hairline outline that turns the single blue when focused, with a floating label. */
@Composable
fun PeeringTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    monospaced: Boolean = false,
) {
    val style = MaterialTheme.typography.bodyLarge
    val borderless = LocalBorderless.current
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        singleLine = singleLine,
        shape = MaterialTheme.shapes.medium,
        label = { Text(label) },
        textStyle = if (monospaced) style.copy(fontFamily = FontFamily.Monospace) else style,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = PeeringColors.accent,
            unfocusedBorderColor = if (borderless) Color.Transparent else PeeringColors.outline,
            unfocusedContainerColor = if (borderless) PeeringColors.surface else Color.Transparent,
            focusedLabelColor = PeeringColors.accent,
            unfocusedLabelColor = PeeringColors.muted,
            cursorColor = PeeringColors.accent,
        ),
    )
}
