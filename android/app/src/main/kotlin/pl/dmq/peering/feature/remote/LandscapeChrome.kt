package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The landscape arrangement: a rail down each side of the top, the status bar between them, the wheel and the pointer
 * column in the bottom corners, and the panel over the middle. The rails stop above the pointer column, which lives
 * where the thumb rests, so the last button cannot slide under it.
 */
@Composable
internal fun LandscapeChrome(
    state: ChromeState,
    handlers: ChromeHandlers,
    panel: @Composable (SessionPanel) -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val railHeight = (maxHeight - POINTER_COLUMN - ChromeMetrics.bottomInset - ChromeMetrics.edgeInset * 2 - ChromeMetrics.panelGap).coerceAtLeast(MIN_RAIL)
        val barWidth = (maxWidth - (ChromeMetrics.panelWidth + ChromeMetrics.edgeInset + ChromeMetrics.panelGap) * 2).coerceIn(0.dp, STATUS_MAX_WIDTH)
        Row(
            Modifier.fillMaxSize().padding(start = ChromeMetrics.edgeInset, end = ChromeMetrics.edgeInset, top = ChromeMetrics.edgeInset),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            ControlRail(Modifier.heightIn(max = railHeight)) {
                listOf(DockControl.KEYS, DockControl.SHORTCUTS, DockControl.CLIPBOARD, DockControl.MODE, DockControl.SOURCES, DockControl.SETTINGS)
                    .forEach { DockControlButton(it, state, handlers) }
            }
            ControlRail(Modifier.heightIn(max = railHeight)) {
                QuickActions.defaults.forEach { action -> ChordRailButton(action.chord, action.label, { handlers.onChord(action) }) }
                listOf(DockControl.ESCAPE, DockControl.TAB, DockControl.UP, DockControl.DOWN, DockControl.LEFT, DockControl.RIGHT, DockControl.DELETE)
                    .forEach { DockControlButton(it, state, handlers) }
            }
        }
        SessionStatusBar(
            state.status, handlers.status, state.statusExpanded, handlers.onPillTap,
            Modifier.align(Alignment.TopCenter).padding(top = ChromeMetrics.edgeInset).widthIn(max = barWidth),
        )
        if (!state.keyboardShown) {
            Row(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = ChromeMetrics.edgeInset).padding(bottom = ChromeMetrics.bottomInset),
                verticalAlignment = Alignment.Bottom,
            ) {
                ScrollWheel(handlers.onNotch, wheelLabel(state), state.wheelPosition)
                Box(Modifier.weight(1f))
                PointerColumn(handlers.pointer, state.speedText)
            }
        }
        val panelHeight = (maxHeight - STATUS_BAR - ChromeMetrics.edgeInset * 2).coerceAtLeast(MIN_RAIL)
        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = if (state.keyboardShown) 0.dp else ChromeMetrics.bottomInset)) {
            FloatingPanel(state.openPanel, panelHeight, Modifier, panel)
            if (state.keyboardShown) KeyboardBar(handlers.keyboardKeys, Modifier.padding(horizontal = ChromeMetrics.edgeInset))
        }
    }
}

private val POINTER_COLUMN: Dp = ChromeMetrics.quickKeySize + ChromeMetrics.panelGap + ChromeMetrics.joystickRadius * 2
private val MIN_RAIL: Dp = 140.dp
private val STATUS_MAX_WIDTH: Dp = 460.dp
private val STATUS_BAR: Dp = 56.dp
