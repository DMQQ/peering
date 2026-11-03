package pl.dmq.peering.feature.sessionmode

import pl.dmq.peering.wire.Modifiers

/** The computer shortcuts the trackpad offers as buttons. Codes are macOS hardware keycodes. */
enum class DockShortcut(val keyCode: Int, val modifiers: Long) {
    SPOTLIGHT(49, Modifiers.COMMAND),
    SWITCH_APP(48, Modifiers.COMMAND),
    MISSION_CONTROL(126, Modifiers.CONTROL),
    SHOW_DESKTOP(103, 0L),
    COPY(8, Modifiers.COMMAND),
    PASTE(9, Modifiers.COMMAND),
    UNDO(6, Modifiers.COMMAND),
    CLOSE_WINDOW(13, Modifiers.COMMAND),
    QUIT_APP(12, Modifiers.COMMAND),
    SCREENSHOT(21, Modifiers.COMMAND or Modifiers.SHIFT),
}
