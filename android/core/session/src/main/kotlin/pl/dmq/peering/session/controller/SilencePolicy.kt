package pl.dmq.peering.session.controller

/**
 * How long the host may stay silent before the link counts as lost. A backgrounded app is throttled by Android
 * (Doze, app standby), so its timers and sockets stall for stretches that say nothing about the connection.
 */
internal object SilencePolicy {
    const val FOREGROUND_LIMIT_SECONDS = 3.0
    const val BACKGROUND_LIMIT_SECONDS = 30.0

    fun limitSeconds(backgrounded: Boolean): Double = if (backgrounded) BACKGROUND_LIMIT_SECONDS else FOREGROUND_LIMIT_SECONDS
}
