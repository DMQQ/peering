package pl.dmq.peering.feature.remote

/** What the system back gesture does on the session screen: the nearest thing to dismiss first, then leaving. */
enum class BackStep {
    HIDE_KEYBOARD,
    ASK_TO_LEAVE;

    companion object {
        fun of(keyboardShown: Boolean): BackStep = if (keyboardShown) HIDE_KEYBOARD else ASK_TO_LEAVE
    }
}
