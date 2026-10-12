package pl.dmq.peering.feature.connect

import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.kit.tappable
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
        Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.connect_first_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            Text(stringResource(R.string.connect_first_body), style = PeeringText.caption, color = PeeringColors.muted)
            Row(
                Modifier
                    .padding(top = 4.dp)
                    .clip(CircleShape)
                    .background(PeeringColors.accent.copy(alpha = 0.18f))
                    .tappable({ uri.openUri("https://getpeering.app/download") })
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(AppIcons.download, null, tint = PeeringColors.accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.connect_first_download), style = PeeringText.subheadlineMedium.copy(fontWeight = FontWeight.Medium), color = PeeringColors.accent)
            }
        }
    }
}
