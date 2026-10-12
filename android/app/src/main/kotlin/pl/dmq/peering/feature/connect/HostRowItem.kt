package pl.dmq.peering.feature.connect

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringRow

/** A Mac in a list. A paired one shows its status dot and a menu to forget it; a nearby one invites pairing. */
@Composable
internal fun HostRowItem(row: HostRow, paired: Boolean, onOpen: () -> Unit, onForget: () -> Unit) {
    PeeringRow(onClick = onOpen) {
        Box {
            IconTile(Icons.Filled.Laptop)
            if (paired) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .size(14.dp)
                        .background(PeeringColors.backdrop, CircleShape),
                    contentAlignment = Alignment.Center,
                ) { StatusDot(row.status) }
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = row.name ?: stringResource(R.string.connect_unnamed_host),
                style = MaterialTheme.typography.titleMedium,
                color = PeeringColors.ink,
                maxLines = 1,
            )
            Text(
                text = stringResource(if (paired) row.status.labelRes() else R.string.connect_nearby_tap_to_pair),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.muted,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
        if (paired) ForgetMenu(onForget) else Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = PeeringColors.faint,
        )
    }
}

@Composable
private fun ForgetMenu(onForget: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.size(40.dp)) {
            Icon(
                Icons.Filled.MoreVert,
                contentDescription = stringResource(R.string.connect_more),
                tint = PeeringColors.muted,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.connect_forget), color = PeeringColors.danger) },
                onClick = {
                    open = false
                    onForget()
                },
            )
        }
    }
}
