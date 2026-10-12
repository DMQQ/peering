package pl.dmq.peering.ui.kit

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * An outlined option for a sheet: a glyph tile, a title, one line saying what it does, and a check when [selected].
 * The selected row takes the accent outline. A [trailing] control replaces the check.
 */
@Composable
fun ChoiceRow(
    icon: ImageVector,
    title: String,
    description: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    role: Role = Role.Button,
    tint: Color = PeeringColors.ink,
    trailing: (@Composable () -> Unit)? = null,
) {
    val shape = peeringShapes.medium
    val outline = if (selected) BorderStroke(2.dp, PeeringColors.accent) else BorderStroke(1.dp, PeeringColors.outline)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(shape)
            .border(outline, shape)
            .clickable(role = role, onClick = onClick)
            .semantics { this.selected = selected }
            .heightIn(min = 64.dp)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        IconTile(icon, size = 40.dp, tint = if (selected) PeeringColors.accent else tint)
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = tint)
            if (description != null) {
                Text(description, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
            }
        }
        when {
            trailing != null -> trailing()
            selected -> Icon(
                imageVector = AppIcons.checkCircle,
                contentDescription = stringResource(R.string.choice_selected),
                tint = PeeringColors.accent,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}
