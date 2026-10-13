package pl.dmq.peering.feature.remote

/** Keys a phone keyboard lacks and a Mac needs: Esc leaves a menu, Tab moves focus, arrows move the caret. */
enum class EditingKey(val macKeyCode: Int, val label: String) {
    ESCAPE(53, "Esc"),
    TAB(48, "Tab"),
    LEFT(123, "←"),
    UP(126, "↑"),
    DOWN(125, "↓"),
    RIGHT(124, "→"),
}
