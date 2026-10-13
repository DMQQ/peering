package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * A row of a [PeeringMenu]: at least 48 dp tall with 16 dp side padding, an optional leading icon and a second line.
 * A destructive item is drawn in the error colour. [selected] marks the current choice with a check in the icon slot.
 */
@Composable
fun PeeringMenuItem(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    supporting: String? = null,
    selected: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
) {
    val tint = if (destructive) PeeringColors.danger else PeeringColors.ink
    val leading = if (selected) AppIcons.check else icon
    DropdownMenuItem(
        text = {
            Column {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                if (supporting != null) {
                    Text(supporting, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
                }
            }
        },
        onClick = onClick,
        modifier = modifier.heightIn(min = 48.dp),
        leadingIcon = leading?.let { { Icon(it, contentDescription = null, modifier = Modifier.size(24.dp)) } },
        enabled = enabled,
        colors = MenuDefaults.itemColors(textColor = tint, leadingIconColor = tint),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
    )
}
