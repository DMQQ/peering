package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.SectionLabel

/** The computers already paired with, each one tap from a session. Absent while there are none. */
@Composable
internal fun PairedSection(hosts: List<HostRow>, actions: ConnectActions, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionLabel(stringResource(R.string.connect_paired_heading), AppIcons.verifiedShield)
        hosts.forEach { row ->
            HostCard(row, paired = true, onOpen = { actions.onConnect(row.id) }, onForget = { actions.onForget(row.id) })
        }
    }
}
