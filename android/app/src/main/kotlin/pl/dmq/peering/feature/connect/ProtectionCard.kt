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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringSwitch
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Whether opening Peering asks for the device's own unlock, and the one way to change it. */
data class AppProtection(val enabled: Boolean, val available: Boolean, val onChange: (Boolean) -> Unit)

@Composable
internal fun ProtectionCard(protection: AppProtection, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTile(AppIcons.fingerprint)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(stringResource(R.string.connect_protect_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            Text(stringResource(R.string.connect_protect_body), style = PeeringText.caption, color = PeeringColors.muted)
        }
        Spacer(Modifier.width(8.dp))
        PeeringSwitch(protection.enabled, protection.onChange, enabled = protection.available)
    }
}
