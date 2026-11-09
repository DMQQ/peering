package pl.dmq.peering.session.video

/**
 * When a viewer that dropped frames asks the computer for a keyframe. Not on the first dropped frame: a session starts by
 * waiting for the keyframe the computer already owes, and a second one would only be a second burst. And not again until
 * the first has had time to arrive.
 */
class KeyframeRequestPolicy {
    private var firstDropAt: Double? = null
    private var lastAskAt: Double? = null

    /** A frame was dropped for want of a keyframe. True when the computer should be asked now. */
    fun noteDrop(nowSeconds: Double): Boolean {
        val started = firstDropAt ?: nowSeconds.also { firstDropAt = it }
        if (nowSeconds - started < GRACE_SECONDS) return false
        lastAskAt?.let { if (nowSeconds - it < COOLDOWN_SECONDS) return false }
        lastAskAt = nowSeconds
        return true
    }

    /** A picture was decoded: the wait is over, and the next one starts its own grace. */
    fun noteRecovered() {
        firstDropAt = null
    }

    companion object {
        const val GRACE_SECONDS = 0.3
        const val COOLDOWN_SECONDS = 1.0
    }
}
