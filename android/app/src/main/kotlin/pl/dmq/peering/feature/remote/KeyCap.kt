package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** One key on the bar. Selected keys are filled with the state blue; a locked key is also outlined in it. */
@Composable
internal fun KeyCap(
    label: String,
    selected: Boolean,
    outlinedInAccent: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    stateText: String? = null,
) {
    val shape = MaterialTheme.shapes.small
    val outline = if (outlinedInAccent) PeeringColors.accent else PeeringColors.hairline
    Box(
        modifier = modifier
            .defaultMinSize(minWidth = 44.dp, minHeight = 40.dp)
            .clip(shape)
            .then(if (selected) Modifier.background(PeeringColors.accent) else Modifier)
            .border(1.dp, outline, shape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { if (stateText != null) stateDescription = stateText }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) PeeringColors.onInk else PeeringColors.ink,
        )
    }
}
