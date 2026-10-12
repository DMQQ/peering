package pl.dmq.peering.feature.remote

/** Decides which controls the toolbar offers. Fit appears only while the picture is zoomed. */
class ToolbarPresenter {
    fun actions(zoomed: Boolean): List<ToolbarAction> = buildList {
        add(ToolbarAction.KEYBOARD)
        add(ToolbarAction.POINTER_MODE)
        if (zoomed) add(ToolbarAction.FIT)
        add(ToolbarAction.SOURCES)
        add(ToolbarAction.QUALITY)
        add(ToolbarAction.MENU)
    }

    fun otherMode(mode: InputMode): InputMode =
        if (mode == InputMode.TRACKPAD) InputMode.DIRECT else InputMode.TRACKPAD
}
