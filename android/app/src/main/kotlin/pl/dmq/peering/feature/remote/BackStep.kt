package pl.dmq.peering.feature.remote

/** What the system back gesture does on the session screen: the nearest thing to dismiss first, then leaving. */
enum class BackStep {
    CLOSE_PANEL,
    HIDE_KEYBOARD,
    ASK_TO_LEAVE;

    companion object {
        fun of(panelOpen: Boolean, keyboardShown: Boolean): BackStep = when {
            panelOpen -> CLOSE_PANEL
            keyboardShown -> HIDE_KEYBOARD
            else -> ASK_TO_LEAVE
        }
    }
}
