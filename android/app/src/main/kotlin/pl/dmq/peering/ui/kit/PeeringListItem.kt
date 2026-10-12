package pl.dmq.peering.ui.kit

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.unit.dp
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.offset
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * Material's list item on a transparent container, so it sits inside an outlined card. At least 56 dp tall, with
 * optional leading and trailing content. Its own 16 dp side padding bleeds into the card's padding so text lines up with the heading. Pass [onClick] to make the whole row the target, with [role] for how it reads.
 */
@Composable
fun PeeringListItem(
    headline: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    onClick: (() -> Unit)? = null,
    role: Role? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val clickable = if (onClick != null) Modifier.clickable(role = role, onClick = onClick) else Modifier
    ListItem(
        headlineContent = { Text(headline, style = MaterialTheme.typography.bodyLarge) },
        modifier = modifier.bleedHorizontally(16.dp).heightIn(min = 56.dp).then(clickable),
        supportingContent = supporting?.let { { Text(it, style = MaterialTheme.typography.bodyMedium) } },
        leadingContent = leading,
        trailingContent = trailing,
        colors = ListItemDefaults.colors(
            containerColor = Color.Transparent,
            headlineColor = PeeringColors.ink,
            supportingColor = PeeringColors.muted,
            leadingIconColor = PeeringColors.muted,
            trailingIconColor = PeeringColors.muted,
        ),
    )
}

private fun Modifier.bleedHorizontally(amount: Dp): Modifier = layout { measurable, constraints ->
    val bleed = amount.roundToPx()
    val placeable = measurable.measure(constraints.offset(horizontal = 2 * bleed))
    layout(placeable.width - 2 * bleed, placeable.height) { placeable.place(-bleed, 0) }
}
