package pl.dmq.peering.widget

data class KnownComputer(val id: String, val name: String)

enum class ComputerPresence { CONNECTED, ONLINE, OFFLINE }

/** What the Quick Connect widget draws: the trusted computers, the one the session is on, and the ones the relay reports up. */
data class QuickConnectSnapshot(
    val computers: List<KnownComputer> = emptyList(),
    val connectedId: String? = null,
    val onlineIds: Set<String> = emptySet(),
) {
    fun presence(id: String): ComputerPresence = when {
        id == connectedId -> ComputerPresence.CONNECTED
        id in onlineIds -> ComputerPresence.ONLINE
        else -> ComputerPresence.OFFLINE
    }

    /** The name the small tile shows: the connected computer, else the first one. */
    val headline: KnownComputer? get() = computers.firstOrNull { it.id == connectedId } ?: computers.firstOrNull()
}

/** In the order a list shows first: the chat waiting on the person, then the busy ones. */
enum class AgentChatTone(val rank: Int) {
    NEEDS_YOU(0),
    WORKING(1),
    FAILED(2),
    FINISHED(3),
}

data class AgentChatEntry(
    val id: String,
    val hostId: String?,
    val title: String,
    val folder: String,
    val tone: AgentChatTone,
    val updatedAtSeconds: Long,
)

/** The chats the widget lists, with the time the app last wrote them. */
data class AgentsSnapshot(
    val chats: List<AgentChatEntry> = emptyList(),
    val publishedAtSeconds: Long = 0,
) {
    val waiting: Int get() = chats.count { it.tone == AgentChatTone.NEEDS_YOU }
    val working: Int get() = chats.count { it.tone == AgentChatTone.WORKING }

    /** A list the app stopped refreshing (it was closed) reads as old, not live. */
    fun isStale(nowSeconds: Long): Boolean = chats.isNotEmpty() && nowSeconds - publishedAtSeconds > STALE_AFTER_SECONDS

    companion object {
        const val STALE_AFTER_SECONDS = 600L
    }
}
