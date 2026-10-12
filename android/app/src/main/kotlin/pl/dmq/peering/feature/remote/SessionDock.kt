package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
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
 * The dock: pages of equal buttons that snap one page per swipe, a chevron at its end that opens it into a wrapped grid,
 * and a row of dots under the buttons for where the page is. [control] draws one of the dock's controls.
 */
@Composable
fun SessionDock(
    groups: List<DockGroup>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    control: @Composable (DockControl, Modifier) -> Unit,
    onChord: (QuickAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val barWidth = maxWidth
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            if (expanded) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .sessionSurface(peeringShapes.large)
                        .blockTouches()
                        .padding(ChromeMetrics.railPadding),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f)) { DockGrid(groups, { c -> control(c, Modifier) }, onChord) }
                    DockToggle(true) { onExpandedChange(false) }
                }
            } else {
                val perPage = DockPaging.perPage((barWidth - ChromeMetrics.dockToggleWidth - ChromeMetrics.railPadding * 2).value, ChromeMetrics.dockSlotMinWidth.value)
                val paging = remember(groups, perPage) { DockPaging.layout(groups, perPage) }
                val applicationId = groups.firstOrNull { it.id.startsWith(DockGroups.APP_PREFIX) }?.id
                val state = rememberDockPagerState(paging, applicationId)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .sessionSurface(peeringShapes.medium)
                        .blockTouches()
                        .padding(ChromeMetrics.railPadding),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f)) { DockPager(paging, state, control, onChord, perPage) }
                    DockToggle(false) { onExpandedChange(true) }
                }
                if (paging.pages.size > 1) DockPageDots(state, paging.pages.size, Modifier.padding(top = 8.dp))
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DockGrid(groups: List<DockGroup>, control: @Composable (DockControl) -> Unit, onChord: (QuickAction) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(max = DockGridMaxHeight).verticalScroll(rememberScrollState())) {
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(ChromeMetrics.buttonGap),
            verticalArrangement = Arrangement.spacedBy(ChromeMetrics.buttonGap),
            maxItemsInEachRow = DockGroups.COLUMNS,
        ) {
            val cell = Modifier.weight(1f)
            groups.forEach { group -> DockGroupButtons(group, control, onChord, cell) }
        }
    }
}

@Composable
private fun DockGroupButtons(group: DockGroup, control: @Composable (DockControl) -> Unit, onChord: (QuickAction) -> Unit, button: Modifier) {
    group.controls.forEach { Box(button, contentAlignment = Alignment.Center) { control(it) } }
    group.actions.forEach { action ->
        ChordRailButton(action.chord, action.label, { onChord(action) }, button)
    }
}

@Composable
private fun DockToggle(expanded: Boolean, onClick: () -> Unit) {
    val label = stringResource(if (expanded) R.string.remote_dock_hide else R.string.remote_dock_show)
    Box(
        Modifier
            .width(ChromeMetrics.dockToggleWidth)
            .height(ChromeMetrics.dockToggleHeight)
            .clip(PillShape)
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(if (expanded) SessionIcons.collapse else AppIcons.expand, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(20.dp))
    }
}

private val DockGridMaxHeight = ChromeMetrics.buttonHeight * 3 + ChromeMetrics.buttonGap * 2
