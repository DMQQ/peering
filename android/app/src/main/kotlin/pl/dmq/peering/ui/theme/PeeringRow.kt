package pl.dmq.peering.ui.theme

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.kit.rowSurface

/** A row resting on a card: the one filled surface in the app. Pressing it shrinks it a hair, with no ripple. */
@Composable
fun PeeringRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = modifier.rowSurface().tappable(onClick).padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}
