package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import pl.dmq.peering.ui.kit.InkButton
import pl.dmq.peering.ui.kit.cardBackground
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** The page name in the display face with one line under it; the question mark appears once the guide has been read. */
@Composable
fun HubHeading(detail: String, showsHelp: Boolean, onHelp: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.agents_title), style = PeeringText.display(size = 34f, tracking = -0.8f), color = PeeringColors.ink)
            Text(detail, style = PeeringText.subheadline, color = PeeringColors.muted, maxLines = 1)
        }
        if (showsHelp) {
            IconButton(onClick = onHelp, modifier = Modifier.size(44.dp)) {
                Icon(AppIcons.help, contentDescription = stringResource(R.string.agents_guide_reopen), tint = PeeringColors.muted)
            }
        }
    }
}

/** What the page is for in a few lines, until it has been read once. */
@Composable
fun HubGuideCard(onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val items = listOf(
        Triple(AppIcons.sparkles, R.string.agents_guide_pick, R.string.agents_guide_pick_detail),
        Triple(AgentIcons.chats, R.string.agents_guide_folder, R.string.agents_guide_folder_detail),
        Triple(AgentIcons.hand, R.string.agents_guide_waiting, R.string.agents_guide_waiting_detail),
    )
    Column(modifier.fillMaxWidth().cardBackground().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.agents_guide_title), style = PeeringText.display(size = 22f, tracking = -0.5f), color = PeeringColors.ink)
        items.forEach { (icon, title, detail) ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                IconTile(icon, size = 34.dp)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                    Text(stringResource(detail), style = PeeringText.footnote, color = PeeringColors.muted)
                }
            }
        }
        InkButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.agents_guide_got_it)) }
    }
}
