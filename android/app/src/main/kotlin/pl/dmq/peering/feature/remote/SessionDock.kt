package pl.dmq.peering.feature.remote

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * The dock: pages of five slots, swiped sideways, with a chevron at its end that opens it to three rows per page. The
 * dots under it are the pages, and tapping one goes there. [control] draws one of the dock's controls.
 */
@Composable
fun SessionDock(
    pages: List<DockPage>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    control: @Composable (DockControl) -> Unit,
    onChord: (QuickAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val pager = rememberPagerState(pageCount = { pages.size })
    var shownId by remember { mutableStateOf(pages.firstOrNull()?.id) }
    LaunchedEffect(pager.currentPage, pages) { pages.getOrNull(pager.currentPage)?.let { shownId = it.id } }
    LaunchedEffect(pages.map { it.id }) {
        val keep = pages.indexOfFirst { it.id == shownId }
        pager.scrollToPage(if (keep >= 0) keep else 0)
    }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(ChromeMetrics.dockDotsGap)) {
        Row(
            Modifier
                .fillMaxWidth()
                .sessionSurface(if (expanded) peeringShapes.large else PillShape)
                .blockTouches()
                .animateContentSize()
                .padding(horizontal = ChromeMetrics.railPadding, vertical = ChromeMetrics.railPadding),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { index ->
                DockPageGrid(pages[index], expanded, control, onChord)
            }
            DockToggle(expanded) { onExpandedChange(!expanded) }
        }
        DockPageDots(pages.size, pager.currentPage) { index -> scope.launch { pager.animateScrollToPage(index) } }
    }
}

@Composable
private fun DockPageGrid(page: DockPage, expanded: Boolean, control: @Composable (DockControl) -> Unit, onChord: (QuickAction) -> Unit) {
    val rows = if (expanded) DockPages.EXPANDED_ROWS else 1
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(ChromeMetrics.buttonGap)) {
        repeat(rows) { row ->
            Row(Modifier.fillMaxWidth().height(ChromeMetrics.buttonHeight)) {
                repeat(DockPages.COLUMNS) { column ->
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        val index = row * DockPages.COLUMNS + column
                        page.controls.getOrNull(index)?.let { control(it) }
                        page.actions.getOrNull(index - page.controls.size)?.let { action ->
                            ChordRailButton(action.chord, action.label, { onChord(action) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DockToggle(expanded: Boolean, onClick: () -> Unit) {
    val label = stringResource(if (expanded) R.string.remote_dock_hide else R.string.remote_dock_show)
    Box(
        Modifier
            .width(ChromeMetrics.dockToggleWidth)
            .height(ChromeMetrics.buttonHeight)
            .clip(PillShape)
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(if (expanded) SessionIcons.collapse else AppIcons.expand, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun DockPageDots(count: Int, current: Int, onSelect: (Int) -> Unit) {
    Row(Modifier.height(ChromeMetrics.dockDotsHeight)) {
        repeat(count) { index ->
            Box(
                Modifier.width(16.dp).height(ChromeMetrics.dockDotsHeight).tappable({ onSelect(index) }),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .size(5.dp)
                        .clip(PillShape)
                        .background(if (index == current) PeeringColors.ink else PeeringColors.muted.copy(alpha = 0.6f)),
                )
            }
        }
    }
}
