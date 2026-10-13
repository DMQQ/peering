package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

@Composable
internal fun PairedSection(hosts: List<HostRow>, actions: ConnectActions, modifier: Modifier = Modifier) {
    var renaming by remember { mutableStateOf<HostRow?>(null) }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SectionLabel(stringResource(R.string.connect_paired_heading), AppIcons.verifiedShield)
        if (hosts.isEmpty()) {
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTile(AppIcons.shield)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.connect_paired_empty), style = PeeringText.subheadline, color = PeeringColors.muted)
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                hosts.forEach { row ->
                    val sharesName = hosts.any { it.id != row.id && it.name == row.name }
                    HostRowCard(
                        row = row,
                        detail = if (sharesName) row.id.take(ID_PREFIX) else stringResource(row.pairedDetailRes()),
                        up = row.status != HostStatus.Unknown,
                        openable = row.status != HostStatus.Unknown,
                        onOpen = { actions.onConnect(row.id) },
                        trailing = { HostMenu(row, actions, onRename = { renaming = row }) },
                    )
                }
            }
        }
    }
    renaming?.let { target ->
        RenameDialog(
            current = target.name.orEmpty(),
            onSave = { name ->
                actions.onRename(target.id, name)
                renaming = null
            },
            onDismiss = { renaming = null },
        )
    }
}
