package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.Symbols
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

/** Computers already paired with, or the sentence that says where they will appear. */
@Composable
internal fun TrustedSection(hosts: List<HostRow>, actions: ConnectActions) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SectionLabel(stringResource(R.string.connect_paired_heading), Symbols.checkmarkShield)
        if (hosts.isEmpty()) {
            Row(Modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTile(Symbols.shield)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.connect_paired_empty), style = PeeringText.subheadline, color = PeeringColors.muted)
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                hosts.forEach { row ->
                    HostRowItem(row, paired = true, onOpen = { actions.onConnect(row.id) }, onForget = { actions.onForget(row.id) })
                }
            }
        }
    }
}
