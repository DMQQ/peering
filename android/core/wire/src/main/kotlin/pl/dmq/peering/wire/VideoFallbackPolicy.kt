package pl.dmq.peering.wire

/**
 * When video leaves the primary lane for the control channel, and when it returns. Times are monotonic
 * seconds, never a wall clock: a device syncing its time must not trip it.
 */
class VideoFallbackPolicy {
    enum class Decision { NONE, USE_CONTROL_CHANNEL, USE_PRIMARY_TRANSPORT }

    var isFallback: Boolean = false
        private set

    private var lastRequestAt: Double? = null
    private var fellBackAt: Double = 0.0
    private var primaryPictures: Int = 0

    fun advance(
        now: Double,
        lastPictureAt: Double?,
        lastControlReplyAt: Double?,
        applies: Boolean,
    ): Decision {
        if (!applies) return Decision.NONE
        return if (isFallback) {
            advanceInFallback(now, lastPictureAt)
        } else {
            advanceOnPrimary(now, lastPictureAt, lastControlReplyAt)
        }
    }

    fun notePrimaryPicture() {
        if (isFallback) primaryPictures += 1
    }

    fun reset() {
        isFallback = false
        lastRequestAt = null
        fellBackAt = 0.0
        primaryPictures = 0
    }

    private fun advanceInFallback(now: Double, lastPictureAt: Double?): Decision {
        if (now - fellBackAt >= MIN_FALLBACK_HOLD && primaryPictures >= PRIMARY_PICTURES_FOR_RETURN) {
            isFallback = false
            primaryPictures = 0
            lastRequestAt = now
            return Decision.USE_PRIMARY_TRANSPORT
        }
        // The host may decline a request, so one that produced no picture is repeated rather than
        // assumed to have worked.
        val askedAt = lastRequestAt ?: 0.0
        val picturedSinceAsking = lastPictureAt != null && lastPictureAt > askedAt
        if (!picturedSinceAsking && now - askedAt >= REQUEST_REPEAT_INTERVAL) {
            lastRequestAt = now
            return Decision.USE_CONTROL_CHANNEL
        }
        return Decision.NONE
    }

    private fun advanceOnPrimary(now: Double, lastPictureAt: Double?, lastControlReplyAt: Double?): Decision {
        if (lastPictureAt == null || now - lastPictureAt < SILENCE_BEFORE_FALLBACK) return Decision.NONE
        // The control channel is about to carry the whole picture, so it must be demonstrably alive.
        val controlAlive = lastControlReplyAt != null && now - lastControlReplyAt <= CONTROL_HEALTH_WINDOW
        if (!controlAlive) return Decision.NONE
        val asked = lastRequestAt
        if (asked != null && now - asked < REQUEST_REPEAT_INTERVAL) return Decision.NONE

        lastRequestAt = now
        fellBackAt = now
        primaryPictures = 0
        isFallback = true
        return Decision.USE_CONTROL_CHANNEL
    }

    companion object {
        /** Measured from the moment the session became ready, so the first three seconds are a probe. */
        const val SILENCE_BEFORE_FALLBACK = 3.0

        /** The client pings once a second, so a pong inside five seconds is four missed round trips. */
        const val CONTROL_HEALTH_WINDOW = 5.0

        /** Also the cooling-off period after a return to the preferred transport. */
        const val REQUEST_REPEAT_INTERVAL = 5.0

        const val MIN_FALLBACK_HOLD = 5.0

        /** Two, not one: a single keyframe datagram can get through on a path otherwise losing everything. */
        const val PRIMARY_PICTURES_FOR_RETURN = 2
    }
}
