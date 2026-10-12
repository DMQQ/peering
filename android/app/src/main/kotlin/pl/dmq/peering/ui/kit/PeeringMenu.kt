package pl.dmq.peering.ui.kit

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The one menu of the app: Material's dropdown on a large rounded container surface with a hairline outline and
 * tonal elevation. It anchors to the box it is called inside and flips or shifts to stay on screen.
 */
@Composable
fun PeeringMenu(expanded: Boolean, onDismiss: () -> Unit, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        modifier = modifier.widthIn(min = 200.dp, max = 320.dp),
        shape = MaterialTheme.shapes.large,
        containerColor = PeeringColors.containerHigh,
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, PeeringColors.hairline),
        content = content,
    )
}

/** A rule between groups of items. */
@Composable
fun PeeringMenuDivider() {
    HorizontalDivider(color = PeeringColors.hairline)
}
