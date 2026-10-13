package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Shown until a first computer is trusted: what to do, and where to get the half that runs on the computer. */
@Composable
internal fun FirstConnectionCard(modifier: Modifier = Modifier) {
    val uri = LocalUriHandler.current
    Row(modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalAlignment = Alignment.Top) {
        IconTile(AppIcons.wifi)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.connect_first_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            Text(stringResource(R.string.connect_first_body), style = PeeringText.caption, color = PeeringColors.muted)
            QuietButton(onClick = { uri.openUri(DOWNLOAD_URL) }, modifier = Modifier.padding(top = 4.dp)) {
                Icon(AppIcons.download, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.connect_first_download), style = PeeringText.subheadlineMedium)
            }
        }
    }
}

private const val DOWNLOAD_URL = "https://getpeering.app/download"
