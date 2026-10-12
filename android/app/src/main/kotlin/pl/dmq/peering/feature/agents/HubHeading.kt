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
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** The page name in the display face with one line under it; the question mark appears once the guide has been read. */
@Composable
fun HubHeading(detail: String, showsHelp: Boolean, onHelp: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
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
    Column(modifier.fillMaxWidth().sessionSurface(peeringShapes.medium).padding(start = 14.dp, top = 4.dp, end = 14.dp, bottom = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                stringResource(R.string.agents_guide_title),
                style = PeeringText.subheadlineSemibold.copy(fontSize = 16.sp),
                color = PeeringColors.ink,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onDismiss, modifier = Modifier.size(40.dp)) {
                Icon(
                    AppIcons.close,
                    contentDescription = stringResource(R.string.agents_guide_dismiss),
                    tint = PeeringColors.muted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            GuideRow(AppIcons.sparkles, R.string.agents_guide_pick, R.string.agents_guide_pick_detail)
            GuideRow(AgentIcons.chats, R.string.agents_guide_folder, R.string.agents_guide_folder_detail)
            GuideRow(AgentIcons.hand, R.string.agents_guide_waiting, R.string.agents_guide_waiting_detail)
        }
        TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
            Text(stringResource(R.string.agents_guide_got_it), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        }
    }
}

@Composable
private fun GuideRow(icon: ImageVector, title: Int, detail: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTile(icon, size = 28.dp)
        Column(Modifier.weight(1f)) {
            Text(stringResource(title), style = PeeringText.subheadlineSemibold.copy(fontSize = 13.5.sp), color = PeeringColors.ink, maxLines = 1)
            Text(stringResource(detail), style = PeeringText.footnote, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
