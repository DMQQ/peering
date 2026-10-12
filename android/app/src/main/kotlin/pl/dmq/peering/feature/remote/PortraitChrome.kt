package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The portrait arrangement: the status bar across the top; the wheel and the pointer row standing on the dock; the dock
 * across the bottom; and the panel between the bar and the dock, drawn over the pointer so none of its controls is
 * covered by a disc that is not part of it. With the keyboard up the dock and the pointer give way to the keyboard card.
 */
@Composable
internal fun PortraitChrome(
    state: ChromeState,
    handlers: ChromeHandlers,
    panel: @Composable (SessionPanel) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    var dockHeight by remember { mutableStateOf(DOCK_ESTIMATE) }
    BoxWithConstraints(modifier.fillMaxSize()) {
        val standing = DOCK_EXPANDED_HEIGHT + ChromeMetrics.panelGap + ChromeMetrics.edgeInset * 2 + STATUS_BAR_HEIGHT
        val panelHeight = (maxHeight - standing).coerceAtLeast(MIN_PANEL_HEIGHT)
        val pointerLift = dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap
        if (state.pointerControlsShown) {
            ScrollWheel(
                onNotch = handlers.onNotch,
                label = wheelLabel(state),
                position = state.wheelPosition,
                modifier = Modifier.align(Alignment.BottomStart).padding(start = ChromeMetrics.edgeInset, bottom = pointerLift),
            )
            PointerRow(handlers.pointer, state.speedText, Modifier.align(Alignment.BottomCenter).padding(bottom = pointerLift))
        }
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
            SessionStatusBar(
                state.status, handlers.status, state.statusExpanded, handlers.onPillTap,
                Modifier.padding(top = ChromeMetrics.edgeInset),
            )
            Box(Modifier.weight(1f))
            FloatingPanel(state.openPanel, panelHeight, Modifier.padding(bottom = if (state.openPanel != null) ChromeMetrics.panelGap else 0.dp), panel)
            if (state.keyboardShown) {
                KeyboardBar(handlers.keyboardKeys, Modifier.padding(horizontal = ChromeMetrics.edgeInset))
            } else {
                SessionDock(
                    groups = DockGroups.of(state.profile),
                    expanded = state.dockExpanded,
                    onExpandedChange = handlers.onDockExpanded,
                    control = { control, modifier -> DockControlButton(control, state, handlers, modifier) },
                    onChord = handlers.onChord,
                    modifier = Modifier
                        .fillMaxWidth(ChromeMetrics.DOCK_WIDTH_FRACTION)
                        .onSizeChanged { dockHeight = with(density) { it.height.toDp() } }
                        .padding(bottom = ChromeMetrics.edgeInset),
                )
            }
        }
    }
}

private val DOCK_ESTIMATE: Dp = 80.dp
private val DOCK_EXPANDED_HEIGHT: Dp = ChromeMetrics.buttonHeight * 3 + ChromeMetrics.buttonGap * 2 + ChromeMetrics.railPadding * 2 + 6.dp + 10.dp
private val STATUS_BAR_HEIGHT: Dp = 44.dp
private val MIN_PANEL_HEIGHT: Dp = 140.dp
