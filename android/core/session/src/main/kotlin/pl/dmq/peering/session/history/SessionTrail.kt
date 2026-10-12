package pl.dmq.peering.session.history

/** The newest [limit] things a session reported, each stamped with seconds since it began, for the detail screen's log. */
class SessionTrail(private val beganAtMillis: Long, private val limit: Int = DEFAULT_LIMIT) {
    private val lines = ArrayDeque<String>()

    val entries: List<String>
        @Synchronized get() = lines.toList()

    @Synchronized
    fun add(message: String, atMillis: Long) {
        val seconds = ((atMillis - beganAtMillis) / MILLIS_PER_SECOND).coerceAtLeast(0)
        lines.addLast("+${seconds}s $message")
        while (lines.size > limit) lines.removeFirst()
    }

    companion object {
        const val DEFAULT_LIMIT = 40
        private const val MILLIS_PER_SECOND = 1_000L
    }
}
