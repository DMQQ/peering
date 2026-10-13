package pl.dmq.peering.session.history

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * The most recent sessions, newest first, for the Sessions tab. A session is recorded when it is asked for and closed
 * when it ends; the oldest records fall off once [limit] is reached. Stored as JSON, so a restored history carries on
 * from where it stopped.
 */
class SessionHistory private constructor(private val limit: Int, initial: List<SessionRecord>) {
    private val entries = ArrayDeque(initial.take(limit))
    private var nextId: Long = (initial.maxOfOrNull { it.id } ?: 0L) + 1

    constructor(limit: Int = DEFAULT_LIMIT) : this(limit, emptyList())

    val records: List<SessionRecord>
        get() = entries.toList()

    /** Records a session that is starting and returns its id, which [end] needs. */
    fun begin(hostId: String, hostName: String, path: SessionRecord.Path, startedAt: Long): Long {
        val record = SessionRecord(
            id = nextId,
            hostId = hostId,
            hostName = hostName,
            startedAt = startedAt,
            path = path,
        )
        nextId += 1
        entries.addFirst(record)
        while (entries.size > limit) entries.removeLast()
        return record.id
    }

    /** Closes an open session. Returns false when no open record has that id, such as one that already fell off. */
    fun end(
        id: Long,
        endedAt: Long,
        reason: SessionRecord.EndReason,
        bytesReceived: Long = 0,
        bytesSent: Long = 0,
        logs: List<String> = emptyList(),
    ): Boolean {
        val index = entries.indexOfFirst { it.id == id && it.endedAt == null }
        if (index < 0) return false
        val record = entries[index]
        // A clock corrected mid-session can read earlier than the start, which would be a negative duration.
        entries[index] = record.copy(endedAt = maxOf(endedAt, record.startedAt),
            reason = reason,
            bytesReceived = bytesReceived,
            bytesSent = bytesSent,
            logs = logs,
        )
        return true
    }

    fun toJson(): String = toJson(records)

    companion object {
        const val DEFAULT_LIMIT = 25

        private val STORAGE = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        fun toJson(records: List<SessionRecord>): String = STORAGE.encodeToString(ListSerializer(SessionRecord.serializer()), records)

        /** Throws when the text is not a history: deciding what an unreadable store means is the caller's job. */
        fun fromJson(text: String, limit: Int = DEFAULT_LIMIT): SessionHistory {
            val decoded = STORAGE.decodeFromString(ListSerializer(SessionRecord.serializer()), text)
            return SessionHistory(limit, decoded)
        }
    }
}
