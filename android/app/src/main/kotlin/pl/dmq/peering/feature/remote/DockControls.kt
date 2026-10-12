package pl.dmq.peering.feature.remote

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons

/** One control of the dock or a rail, drawn as the phone draws it and wired to the chrome's handlers. */
@Composable
internal fun DockControlButton(control: DockControl, state: ChromeState, handlers: ChromeHandlers, modifier: Modifier = Modifier) {
    when (control) {
        DockControl.SOURCES -> RailButton(
            SessionIcons.apps, stringResource(R.string.remote_dock_apps), { handlers.onPanel(SessionPanel.SOURCES) },
            modifier, selected = state.openPanel == SessionPanel.SOURCES,
        )
        DockControl.KEYS -> RailButton(
            if (state.keyboardShown) SessionIcons.keyboardOn else SessionIcons.keyboard,
            stringResource(R.string.remote_keyboard), handlers.onKeyboard, modifier, selected = state.keyboardShown,
        )
        DockControl.CLIPBOARD -> RailButton(
            SessionIcons.clipboard, stringResource(R.string.remote_dock_clipboard), { handlers.onPanel(SessionPanel.CLIPBOARD) },
            modifier, selected = state.openPanel == SessionPanel.CLIPBOARD,
        )
        DockControl.SHORTCUTS -> RailButton(
            AppIcons.command, stringResource(R.string.remote_dock_shortcuts), { handlers.onPanel(SessionPanel.SHORTCUTS) },
            modifier, selected = state.openPanel == SessionPanel.SHORTCUTS,
        )
        DockControl.TAB -> RailButton(SessionIcons.tab, stringResource(R.string.remote_key_tab), { handlers.onKey(TAB, 0L) }, modifier)
        DockControl.LEFT -> RailButton(SessionIcons.left, stringResource(R.string.remote_dock_left), { handlers.onKey(LEFT, 0L) }, modifier)
        DockControl.UP -> RailButton(SessionIcons.up, stringResource(R.string.remote_dock_up), { handlers.onKey(UP, 0L) }, modifier)
        DockControl.DOWN -> RailButton(SessionIcons.down, stringResource(R.string.remote_dock_down), { handlers.onKey(DOWN, 0L) }, modifier)
        DockControl.RIGHT -> RailButton(SessionIcons.right, stringResource(R.string.remote_dock_right), { handlers.onKey(RIGHT, 0L) }, modifier)
        DockControl.DELETE -> RailButton(SessionIcons.delete, stringResource(R.string.remote_key_delete), handlers.onDelete, modifier)
        DockControl.ESCAPE -> RailButton(SessionIcons.escape, stringResource(R.string.remote_key_escape_short), { handlers.onKey(ESCAPE, 0L) }, modifier)
        DockControl.MODE -> RailButton(
            state.interaction.icon(), stringResource(state.interaction.labelRes()), handlers.onMode, modifier,
            selected = state.interaction == InputMode.OBSERVE,
        )
        DockControl.SETTINGS -> RailButton(
            SessionIcons.settings, stringResource(R.string.remote_dock_settings), { handlers.onPanel(SessionPanel.SETTINGS) },
            modifier, selected = state.openPanel == SessionPanel.SETTINGS,
        )
    }
}

private fun InputMode.icon() = when (this) {
    InputMode.TRACKPAD -> AppIcons.trackpad
    InputMode.DIRECT -> AppIcons.tap
    InputMode.OBSERVE -> AppIcons.observe
}

private fun InputMode.labelRes() = when (this) {
    InputMode.TRACKPAD -> R.string.settings_interaction_control
    InputMode.DIRECT -> R.string.settings_interaction_touch
    InputMode.OBSERVE -> R.string.settings_interaction_observe
}
