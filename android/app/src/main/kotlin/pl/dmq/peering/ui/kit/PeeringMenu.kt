package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.ui.theme.PeeringColors

/** Material's dropdown menu on the palette's raised surface. Call it inside the anchor's box. */
@Composable
fun PeeringMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, containerColor = PeeringColors.containerHigh, content = content)
}

@Composable
fun MenuItem(title: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier, destructive: Boolean = false, enabled: Boolean = true) {
    val tint = if (destructive) PeeringColors.danger else PeeringColors.ink
    DropdownMenuItem(
        text = { Text(title, style = MaterialTheme.typography.bodyLarge) },
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        trailingIcon = { Icon(icon, contentDescription = null) },
        colors = androidx.compose.material3.MenuDefaults.itemColors(textColor = tint, trailingIconColor = tint),
    )
}
