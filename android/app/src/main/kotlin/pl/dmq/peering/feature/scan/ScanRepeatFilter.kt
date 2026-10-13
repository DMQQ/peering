package pl.dmq.peering.feature.scan

/**
 * Lets a code through once while it stays in view. A steady code is read on every frame, and a pairing must start once.
 * Each sighting restarts the quiet window, so a code held in view is never let through twice.
 */
internal class ScanRepeatFilter(private val quietMillis: Long = DEFAULT_QUIET_MILLIS) {
    private var lastText: String? = null
    private var lastSeenAt = 0L

    fun accept(text: String, nowMillis: Long): Boolean {
        val repeat = text == lastText && nowMillis - lastSeenAt < quietMillis
        lastText = text
        lastSeenAt = nowMillis
        return !repeat
    }

    private companion object {
        const val DEFAULT_QUIET_MILLIS = 2_000L
    }
}
