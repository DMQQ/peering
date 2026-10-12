package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.MenuItem
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** A computer in a list: its tile with the presence dot, its name and a line of monospaced detail. A trusted one adds a menu. */
@Composable
internal fun HostRowItem(row: HostRow, paired: Boolean, onOpen: () -> Unit, onForget: (() -> Unit)?) {
    Row(Modifier.rowSurface().padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).tappable(onOpen), verticalAlignment = Alignment.CenterVertically) {
            Box {
                IconTile(AppIcons.computer)
                StatusDot(up = !paired || row.status != HostStatus.Unknown, modifier = Modifier.align(Alignment.BottomEnd))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(2.dp)) {
                Text(
                    row.name ?: stringResource(R.string.connect_unnamed_host),
                    style = PeeringText.subheadlineSemibold.copy(fontWeight = FontWeight.SemiBold),
                    color = PeeringColors.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (paired) stringResource(row.status.labelRes()) else row.id.take(DISPLAYED_ID_LENGTH),
                    style = PeeringText.caption2Monospaced,
                    color = PeeringColors.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (onForget != null) TrustedMenu(onForget)
    }
}

@Composable
private fun TrustedMenu(onForget: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.size(36.dp).tappable({ open = true }), contentAlignment = Alignment.Center) {
            Icon(AppIcons.more, stringResource(R.string.connect_more), tint = PeeringColors.muted, modifier = Modifier.size(22.dp))
        }
        PeeringMenu(open, { open = false }) {
            MenuItem(stringResource(R.string.connect_forget), AppIcons.delete, { open = false; onForget() }, destructive = true)
        }
    }
}

private const val DISPLAYED_ID_LENGTH = 8
