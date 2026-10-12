package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.CardShape
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * A computer as one outlined card: its icon with a presence dot, its name, and one line for its state and route. A
 * paired computer adds a menu; a nearby one a chevron, since tapping it starts pairing.
 */
@Composable
internal fun HostCard(row: HostRow, paired: Boolean, onOpen: () -> Unit, onForget: (() -> Unit)?, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(CardShape)
            .cardBackground()
            .tappable(onOpen)
            .heightIn(min = 72.dp)
            .padding(start = 16.dp, end = if (onForget != null) 4.dp else 16.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            IconTile(AppIcons.computer)
            StatusDot(up = !paired || row.status != HostStatus.Unknown, modifier = Modifier.align(Alignment.BottomEnd))
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                row.name ?: stringResource(R.string.connect_unnamed_host),
                style = MaterialTheme.typography.titleMedium,
                color = PeeringColors.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                stringResource(row.supportingRes(paired)),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (onForget != null) {
            HostMenu(onForget)
        } else {
            Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun HostMenu(onForget: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(AppIcons.more, stringResource(R.string.connect_more), tint = PeeringColors.muted)
        }
        PeeringMenu(open, { open = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.connect_forget),
                onClick = {
                    open = false
                    onForget()
                },
                icon = AppIcons.delete,
                destructive = true,
            )
        }
    }
}
