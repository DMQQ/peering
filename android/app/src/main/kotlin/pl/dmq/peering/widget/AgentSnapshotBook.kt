package pl.dmq.peering.widget

/** The chats of every computer the phone has open, merged into the one ordered list the widget shows. */
class AgentSnapshotBook {
    private val byHost = mutableMapOf<String, List<AgentChatEntry>>()

    /** False when [chats] is what the book already held, apart from the clock. */
    fun update(hostKey: String, chats: List<AgentChatEntry>): Boolean {
        if (byHost[hostKey].orEmpty().map(::withoutClock) == chats.map(::withoutClock)) return false
        if (chats.isEmpty()) byHost.remove(hostKey) else byHost[hostKey] = chats
        return true
    }

    /** A computer that is no longer open has no chats this phone can show. */
    fun prune(keeping: Set<String>): Boolean {
        val before = byHost.size
        byHost.keys.retainAll(keeping)
        return byHost.size != before
    }

    fun merged(): List<AgentChatEntry> = ordered(byHost.values.flatten()).take(WidgetLimits.MAX_CHATS)

    private fun withoutClock(entry: AgentChatEntry) = entry.copy(updatedAtSeconds = 0)

    companion object {
        fun ordered(chats: List<AgentChatEntry>): List<AgentChatEntry> =
            chats.sortedWith(compareBy<AgentChatEntry> { it.tone.rank }.thenByDescending { it.updatedAtSeconds })
    }
}
