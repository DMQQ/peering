package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.ChromeMetrics
import pl.dmq.peering.feature.remote.RailButton
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.theme.DockCollapsedShape
import pl.dmq.peering.wire.SpaceDisplay

/** What the trackpad's bar asks for. The bar draws; the dock acts. */
class RemoteDockBarActions(
    val onKeyboard: () -> Unit,
    val onDesktops: () -> Unit,
    val onApps: () -> Unit,
    val onShortcuts: () -> Unit,
    val onLock: () -> Unit,
    val onKey: (Int) -> Unit,
)

/** Which of the bar's buttons the host can act on. */
data class RemoteDockButtons(val desktops: Boolean, val apps: Boolean, val lock: Boolean)

/** The trackpad's bar, drawn as the screen view's dock is. While typing it holds the keys the soft keyboard lacks. */
@Composable
fun RemoteDockBar(typing: Boolean, desktops: SpaceDisplay?, buttons: RemoteDockButtons, actions: RemoteDockBarActions, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().sessionSurface(DockCollapsedShape).padding(ChromeMetrics.railPadding),
        horizontalArrangement = Arrangement.spacedBy(ChromeMetrics.buttonGap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (typing) TypingKeys(actions.onKey) else MainButtons(desktops, buttons, actions)
    }
}

@Composable
private fun RowScope.MainButtons(desktops: SpaceDisplay?, buttons: RemoteDockButtons, actions: RemoteDockBarActions) {
    val cell = Modifier.weight(1f)
    RailButton(SessionIcons.keyboard, stringResource(R.string.dock_keyboard), actions.onKeyboard, cell)
    if (buttons.desktops) DesktopsButton(desktops, actions, cell)
    if (buttons.apps) RailButton(SessionIcons.apps, stringResource(R.string.remote_dock_apps), actions.onApps, cell)
    RailButton(AppIcons.command, stringResource(R.string.remote_dock_shortcuts), actions.onShortcuts, cell)
    if (buttons.lock) RailButton(AppIcons.encrypted, stringResource(R.string.dock_lock), actions.onLock, cell)
}

@Composable
private fun RowScope.TypingKeys(onKey: (Int) -> Unit) {
    val cell = Modifier.weight(1f)
    RailButton(SessionIcons.escape, stringResource(R.string.remote_key_escape_short), { onKey(ESCAPE) }, cell)
    RailButton(SessionIcons.tab, stringResource(R.string.remote_key_tab), { onKey(TAB) }, cell)
    RailButton(SessionIcons.left, stringResource(R.string.remote_dock_left), { onKey(LEFT) }, cell)
    RailButton(SessionIcons.up, stringResource(R.string.remote_dock_up), { onKey(UP) }, cell)
    RailButton(SessionIcons.down, stringResource(R.string.remote_dock_down), { onKey(DOWN) }, cell)
    RailButton(SessionIcons.right, stringResource(R.string.remote_dock_right), { onKey(RIGHT) }, cell)
}

/** Names the desktop the computer is on; a tap opens the sheet of every desktop. */
@Composable
private fun DesktopsButton(display: SpaceDisplay?, actions: RemoteDockBarActions, modifier: Modifier) {
    val current = display?.current
    val title = if (current != null) stringResource(R.string.dock_desktop_number, current) else stringResource(R.string.dock_desktops)
    RailButton(AppIcons.spaces, title, actions.onDesktops, modifier)
}

private const val ESCAPE = 53
private const val TAB = 48
private const val LEFT = 123
private const val DOWN = 125
private const val UP = 126
private const val RIGHT = 124
