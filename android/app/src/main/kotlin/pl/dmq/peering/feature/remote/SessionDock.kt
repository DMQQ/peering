package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.first
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
 * The dock: one row of buttons that scrolls sideways, a thin divider between the groups, and a chevron at its end that
 * opens it into a wrapped grid. [control] draws one of the dock's controls.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SessionDock(
    groups: List<DockGroup>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    control: @Composable (DockControl) -> Unit,
    onChord: (QuickAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .sessionSurface(if (expanded) peeringShapes.large else PillShape)
            .blockTouches()
            .padding(ChromeMetrics.railPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (expanded) DockGrid(groups, control, onChord) else DockStrip(groups, control, onChord)
        }
        DockToggle(expanded) { onExpandedChange(!expanded) }
    }
}

@Composable
private fun DockStrip(groups: List<DockGroup>, control: @Composable (DockControl) -> Unit, onChord: (QuickAction) -> Unit) {
    val scroll = rememberScrollState()
    var applicationStart by remember { mutableFloatStateOf(0f) }
    val applicationId = groups.firstOrNull { it.id.startsWith(DockGroups.APP_PREFIX) }?.id
    LaunchedEffect(applicationId) {
        if (applicationId != null) {
            val start = snapshotFlow { applicationStart }.first { it > 0f }
            scroll.animateScrollTo(start.toInt())
        }
    }
    val fade = ChromeMetrics.railPadding * 6
    Row(
        Modifier
            .fillMaxWidth()
            .height(ChromeMetrics.dockBarHeight - ChromeMetrics.railPadding * 2)
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                val width = fade.toPx()
                if (scroll.canScrollBackward) {
                    drawRect(Brush.horizontalGradient(listOf(Color.Transparent, Color.Black), 0f, width), size = size.copy(width = width), blendMode = BlendMode.DstIn)
                }
                if (scroll.canScrollForward) {
                    val from = size.width - width
                    drawRect(
                        Brush.horizontalGradient(listOf(Color.Black, Color.Transparent), from, size.width),
                        topLeft = Offset(from, 0f), size = size.copy(width = width), blendMode = BlendMode.DstIn,
                    )
                }
            }
            .horizontalScroll(scroll),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val button = Modifier.widthIn(min = ChromeMetrics.dockButtonMinWidth).height(ChromeMetrics.dockButtonHeight)
        groups.forEachIndexed { index, group ->
            if (index > 0) GroupDivider()
            val position = if (group.id.startsWith(DockGroups.APP_PREFIX)) Modifier.onGloballyPositioned { applicationStart = it.positionInParent().x } else Modifier
            Row(position) { DockGroupButtons(group, control, onChord, button) }
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
private fun GroupDivider() {
    Box(
        Modifier
            .padding(horizontal = 6.dp)
            .width(1.dp)
            .height(24.dp)
            .background(PeeringColors.muted.copy(alpha = 0.35f)),
    )
}

@Composable
private fun DockToggle(expanded: Boolean, onClick: () -> Unit) {
    val label = stringResource(if (expanded) R.string.remote_dock_hide else R.string.remote_dock_show)
    Box(
        Modifier
            .width(ChromeMetrics.dockToggleWidth)
            .height(ChromeMetrics.dockButtonHeight)
            .clip(PillShape)
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(if (expanded) SessionIcons.collapse else AppIcons.expand, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(20.dp))
    }
}

private val DockGridMaxHeight = ChromeMetrics.buttonHeight * 3 + ChromeMetrics.buttonGap * 2
