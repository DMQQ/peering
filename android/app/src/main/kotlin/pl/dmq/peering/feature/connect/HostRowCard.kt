package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * A computer as a filled row on the card: its tile with a presence dot, its name, and a monospaced detail line.
 * [trailing] is the menu of a trusted computer; a nearby one has nothing there, since tapping it starts pairing.
 */
@Composable
internal fun HostRowCard(
    row: HostRow,
    detail: String,
    up: Boolean,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier.fillMaxWidth().rowSurface().padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.weight(1f).tappable(onOpen), verticalAlignment = Alignment.CenterVertically) {
            Box {
                IconTile(AppIcons.computer)
                StatusDot(up = up, modifier = Modifier.align(Alignment.BottomEnd))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    row.name ?: stringResource(R.string.connect_unnamed_host),
                    style = PeeringText.subheadlineSemibold,
                    color = PeeringColors.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(detail, style = PeeringText.caption2Monospaced, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        trailing?.invoke()
    }
}
