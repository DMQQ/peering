package pl.dmq.peering.feature.terminal

import pl.dmq.peering.ui.kit.tonalCard
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import pl.dmq.peering.ui.theme.peeringShapes
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentIcons
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.displayFamily

private val guideShape get() = peeringShapes.large

private class GuideItem(val icon: ImageVector, val title: Int, val detail: Int)

private val guideItems = listOf(
    GuideItem(TerminalGlyphs.terminal, R.string.terminal_guide_shell, R.string.terminal_guide_shell_detail),
    GuideItem(TerminalGlyphs.add, R.string.terminal_guide_start, R.string.terminal_guide_start_detail),
    GuideItem(AgentIcons.hand, R.string.terminal_guide_manage, R.string.terminal_guide_manage_detail),
    GuideItem(AgentIcons.review, R.string.terminal_guide_needs_you, R.string.terminal_guide_needs_you_detail),
)

/** What the page is for, until it has been read once: an outlined card, four tiles with a line each, and a white "Got it". */
@Composable
fun TerminalGuideCard(onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxWidth().tonalCard(guideShape).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(R.string.terminal_guide_title),
            color = PeeringColors.ink,
            fontFamily = displayFamily,
            fontSize = 22.sp,
            letterSpacing = (-0.5).sp,
        )
        guideItems.forEach { item ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                IconTile(item.icon, size = 34.dp)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(item.title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                    Text(stringResource(item.detail), style = PeeringText.footnote, color = PeeringColors.muted)
                }
            }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clip(PillShape)
                .background(PeeringColors.ink)
                .clickable(role = Role.Button, onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Text(stringResource(R.string.agents_guide_got_it), style = PeeringText.subheadlineSemibold, color = PeeringColors.onInk)
        }
    }
}
