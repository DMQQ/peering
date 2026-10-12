package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/** An outlined field with a magnifier and a clear button, as the phone's search fields are drawn. */
@Composable
fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    height: Dp = 38.dp,
    filled: Boolean = false,
) {
    val shape = if (filled) PillShape else peeringShapes.extraSmall
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .let { if (filled) it.background(PeeringColors.surface, shape) else it.border(1.dp, PeeringColors.outline.copy(alpha = 0.36f), shape) }
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SessionIcons.search, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f).padding(start = 8.dp)) {
            if (query.isEmpty()) Text(placeholder, style = PeeringText.subheadline, color = PeeringColors.tertiary)
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = PeeringText.subheadline.copy(color = PeeringColors.ink),
                cursorBrush = SolidColor(PeeringColors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                SessionIcons.clearSearch,
                contentDescription = stringResource(R.string.search_clear),
                tint = PeeringColors.tertiary,
                modifier = Modifier.size(20.dp).tappable({ onQueryChange("") }),
            )
        }
    }
}
