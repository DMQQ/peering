package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** A row whose trailing control prints the current value and opens a menu of [options]. */
@Composable
fun <T> ControlPicker(
    title: String,
    icon: ImageVector,
    selected: T,
    options: List<T>,
    optionTitle: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    ControlRow(title, icon, modifier) {
        Box {
            Row(
                Modifier.clip(peeringShapes.extraSmall).tappable({ open = true }, role = Role.DropdownList),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(optionTitle(selected), style = PeeringText.subheadline, color = PeeringColors.muted)
                Spacer(Modifier.width(6.dp))
                Icon(SessionIcons.unfold, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
            }
            PeeringMenu(expanded = open, onDismiss = { open = false }) {
                options.forEach { option ->
                    PeeringMenuItem(
                        title = optionTitle(option),
                        selected = option == selected,
                        onClick = {
                            open = false
                            onSelect(option)
                        },
                    )
                }
            }
        }
    }
}

/** A row that does something when tapped, with an arrow at the end saying whether it stays in the app or leaves it. */
@Composable
fun ControlLink(
    title: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    external: Boolean = false,
    detail: String? = null,
) {
    ControlRow(title, icon, modifier.clip(peeringShapes.extraSmall).tappable(onClick)) {
        if (detail != null) Text(detail, style = PeeringText.captionSemibold, color = PeeringColors.muted)
        Icon(
            if (external) AppIcons.openExternal else AppIcons.chevronRight,
            contentDescription = null,
            tint = PeeringColors.tertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}
