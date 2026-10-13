package pl.dmq.peering.session.controller

/**
 * A network move while the app is backgrounded leaves the socket dead without a signal, and the 30 s backgrounded silence
 * limit would let it sit. On return the host is pinged at once and gets [SilencePolicy.FOREGROUND_LIMIT_SECONDS] to answer.
 */
internal class ReturnProbe {
    private var movedWhileAway = false

    fun networkMoved(backgrounded: Boolean) {
        if (backgrounded) movedWhileAway = true
    }

    /** True once per move: the caller pings the host now and counts the silence from now. */
    fun onReturn(): Boolean {
        val due = movedWhileAway
        movedWhileAway = false
        return due
    }
}
