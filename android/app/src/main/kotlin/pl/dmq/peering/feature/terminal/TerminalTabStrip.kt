package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors

/** What a tab can be asked to do besides being selected. */
class TerminalTabActions(
    val onSelect: (TerminalTab) -> Unit,
    val onClose: (TerminalTab) -> Unit,
    val onRename: (TerminalTab) -> Unit,
    val onCopy: (TerminalTab) -> Unit,
)

/**
 * The shells as a strip of monospaced names over a hairline, scrolled to keep the selection in view. The trailing
 * plus is pinned outside the scroller, so it stays put however long the row gets.
 */
@Composable
fun TerminalTabStrip(
    tabs: List<TerminalTab>,
    selectedID: String?,
    hasOutput: @Composable (TerminalTab) -> Boolean,
    actions: TerminalTabActions,
    onNew: () -> Unit,
    newEnabled: Boolean,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    val selectedIndex = tabs.indexOfFirst { it.id == selectedID }
    LaunchedEffect(selectedIndex) {
        if (selectedIndex >= 0) listState.animateScrollToItem(selectedIndex)
    }
    Box(modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Top) {
            LazyRow(
                state = listState,
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(start = 8.dp, end = 4.dp, top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                itemsIndexed(tabs, key = { _, tab -> tab.id }) { _, tab ->
                    TerminalTabChip(tab, tab.id == selectedID, terminalMark(tab, hasOutput(tab)), actions)
                }
            }
            IconButton(onClick = onNew, enabled = newEnabled, modifier = Modifier.padding(top = 4.dp).size(40.dp)) {
                Icon(TerminalGlyphs.add, stringResource(R.string.terminal_new), tint = PeeringColors.ink, modifier = Modifier.size(20.dp))
            }
        }
        HorizontalDivider(Modifier.align(Alignment.BottomCenter), color = PeeringColors.hairline)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TerminalTabChip(tab: TerminalTab, selected: Boolean, mark: TerminalMark, actions: TerminalTabActions) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier.combinedClickable(
                onClick = { actions.onSelect(tab) },
                onDoubleClick = { actions.onRename(tab) },
                onLongClick = { menuOpen = true },
            ),
        ) {
            Row(
                Modifier.height(32.dp).widthIn(min = 88.dp, max = 190.dp).padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TerminalMarkGlyph(mark)
                Spacer(Modifier.width(7.dp))
                Text(
                    tab.name,
                    modifier = Modifier.weight(1f, fill = false),
                    color = terminalNameColour(mark, selected),
                    fontSize = 12.5.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val closeLabel = stringResource(R.string.terminal_close_named, tab.name)
                Box(
                    Modifier.size(width = 22.dp, height = 32.dp).tappable({ actions.onClose(tab) }),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(AppIcons.close, closeLabel, tint = PeeringColors.muted, modifier = Modifier.size(10.dp))
                }
            }
            Box(
                Modifier.padding(horizontal = 9.dp).padding(bottom = 5.dp).fillMaxWidth().height(2.dp).clip(CircleShape)
                    .background(if (selected) PeeringColors.ink else Color.Transparent),
            )
        }
        PeeringMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
            PeeringMenuItem(stringResource(R.string.terminal_rename), icon = AppIcons.edit, onClick = {
                menuOpen = false
                actions.onRename(tab)
            })
            PeeringMenuItem(stringResource(R.string.terminal_copy), icon = AppIcons.copy, onClick = {
                menuOpen = false
                actions.onCopy(tab)
            })
            PeeringMenuItem(stringResource(R.string.terminal_end), icon = AppIcons.close, destructive = true, onClick = {
                menuOpen = false
                actions.onClose(tab)
            })
        }
    }
}

/** A state's tint wins over selection, so a terminal wanting a password is found at a glance. */
private fun terminalNameColour(mark: TerminalMark, selected: Boolean): Color = when (mark) {
    TerminalMark.PASSWORD, TerminalMark.QUESTION -> PeeringColors.accent
    TerminalMark.FAILED -> PeeringColors.danger
    TerminalMark.STOPPED -> PeeringColors.ink.copy(alpha = 0.3f)
    else -> if (selected) PeeringColors.ink else PeeringColors.muted
}

@Composable
private fun TerminalMarkGlyph(mark: TerminalMark) {
    Box(Modifier.size(14.dp), contentAlignment = Alignment.Center) {
        when (mark) {
            TerminalMark.STARTING -> PeeringSpinner(size = 11.dp, color = PeeringColors.muted)
            TerminalMark.PASSWORD -> MarkIcon(AppIcons.encrypted, PeeringColors.accent)
            TerminalMark.QUESTION -> MarkIcon(AppIcons.help, PeeringColors.accent)
            TerminalMark.FAILED -> MarkIcon(AppIcons.warning, PeeringColors.danger)
            TerminalMark.RUNNING -> MarkIcon(TerminalGlyphs.terminal, PeeringColors.muted)
            TerminalMark.STOPPED -> MarkIcon(TerminalGlyphs.terminal, PeeringColors.ink.copy(alpha = 0.3f))
        }
    }
}

@Composable
private fun MarkIcon(icon: ImageVector, tint: Color) {
    Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
}
