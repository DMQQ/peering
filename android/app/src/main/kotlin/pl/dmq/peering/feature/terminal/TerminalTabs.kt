package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.theme.PeeringColors

/** One Material tab per shell. A dot marks a shell that is waiting on the user. */
@Composable
fun TerminalTabs(tabs: List<TerminalTab>, selectedID: String?, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val selected = tabs.indexOfFirst { it.id == selectedID }.coerceAtLeast(0)
    ScrollableTabRow(
        selectedTabIndex = selected,
        modifier = modifier,
        containerColor = Color.Transparent,
        contentColor = PeeringColors.ink,
        edgePadding = 8.dp,
    ) {
        tabs.forEach { tab ->
            Tab(
                selected = tab.id == selectedID,
                onClick = { onSelect(tab.id) },
                selectedContentColor = PeeringColors.ink,
                unselectedContentColor = PeeringColors.muted,
            ) {
                Row(modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(tab.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (tab.attention != null) {
                        Spacer(Modifier.width(6.dp))
                        Spacer(Modifier.size(8.dp).clip(CircleShape).background(PeeringColors.accent))
                    }
                }
            }
        }
    }
}
