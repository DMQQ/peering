package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

@Composable
internal fun FailureCard(message: ConnectMessage, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalAlignment = Alignment.Top) {
        if (message.isFailure) IconTile(AppIcons.warning, tint = PeeringColors.caution) else IconTile(AppIcons.checkCircle)
        Spacer(Modifier.width(12.dp))
        Text(
            message.text(),
            style = PeeringText.caption,
            color = PeeringColors.muted,
            modifier = Modifier.weight(1f).padding(top = 2.dp),
        )
        IconButton(onClick = onDismiss, modifier = Modifier.size(28.dp)) {
            Icon(AppIcons.close, stringResource(R.string.connect_dismiss_error), tint = PeeringColors.muted, modifier = Modifier.size(16.dp))
        }
    }
}
