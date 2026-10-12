package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** iOS `.textFieldStyle(.plain)` on a 0.06 white fill, radius 12, 12 of padding. */
@Composable
fun PeeringTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        singleLine = singleLine,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        textStyle = PeeringText.body.copy(color = PeeringColors.ink),
        cursorBrush = SolidColor(PeeringColors.ink),
        decorationBox = { field ->
            Box(Modifier.background(PeeringColors.ink.copy(alpha = 0.06f), ContinuousShape(12.dp)).padding(12.dp)) {
                if (value.isEmpty()) Text(placeholder, style = PeeringText.body, color = PeeringColors.tertiary)
                field()
            }
        },
    )
}
