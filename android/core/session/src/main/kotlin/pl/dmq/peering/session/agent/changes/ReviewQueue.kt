package pl.dmq.peering.session.agent.changes

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentChangesReport

/** A stable digest of one file's change, so a reviewed mark can tell when the file has moved on. FNV-1a over the kind, the counts and the diff. */
object ReviewFingerprint {
    private const val OFFSET = -0x340d631b7bdddcdbL
    private const val PRIME = 0x100000001b3L

    fun of(file: AgentChangedFile): String {
        var hash = OFFSET
        fun mix(text: String) {
            for (byte in text.toByteArray(Charsets.UTF_8)) hash = (hash xor (byte.toLong() and 0xff)) * PRIME
            hash = (hash xor 0x1f) * PRIME
        }
        mix(file.kind.name)
        mix(file.added.toString())
        mix(file.removed.toString())
        mix(file.diff.orEmpty())
        return java.lang.Long.toHexString(hash)
    }
}

/** Which files the reader has marked reviewed, per chat, each tied to the fingerprint it had when marked. */
@Serializable
data class ReviewMarks(private val marks: Map<String, Map<String, String>> = emptyMap()) {
    fun isReviewed(file: AgentChangedFile, chatId: String): Boolean = marks[chatId]?.get(file.path) == ReviewFingerprint.of(file)

    fun withReviewed(reviewed: Boolean, file: AgentChangedFile, chatId: String): ReviewMarks {
        val chat = marks[chatId].orEmpty()
        val next = if (reviewed) chat + (file.path to ReviewFingerprint.of(file)) else chat - file.path
        return ReviewMarks(if (next.isEmpty()) marks - chatId else marks + (chatId to next))
    }

    /** Forgets marks a newer answer has outdated: a file that changed again or left the list. Only a real answer prunes, so a failed one cannot wipe the marks. */
    fun pruned(chatId: String, report: AgentChangesReport): ReviewMarks {
        if (!report.isRepository) return this
        val kept = marks[chatId] ?: return this
        val current = report.files.associate { it.path to ReviewFingerprint.of(it) }
        val still = kept.filter { current[it.key] == it.value }
        return if (still.size == kept.size) this else ReviewMarks(if (still.isEmpty()) marks - chatId else marks + (chatId to still))
    }

    /** Drops every mark of a chat that no longer exists. */
    fun retaining(chats: Set<String>): ReviewMarks = if (marks.keys.all { it in chats }) this else ReviewMarks(marks.filterKeys { it in chats })
}

/** The marks as one value in the phone's key-value store. A value that cannot be read is treated as none made. */
class ReviewMarkStore(private val store: KeyValueStore, private val key: String = "agent_review_marks") {
    fun load(): ReviewMarks =
        store.read(key)?.let { raw -> runCatching { Json.decodeFromString<ReviewMarks>(raw) }.getOrNull() } ?: ReviewMarks()

    fun save(marks: ReviewMarks) = store.write(key, Json.encodeToString(ReviewMarks.serializer(), marks))
}

/** What the review list knows about one chat's changes, and how far to trust it. */
data class ReviewSource(
    val chatId: String,
    val title: String,
    val directory: String,
    val report: AgentChangesReport?,
    val loading: Boolean,
)

data class ReviewFile(val file: AgentChangedFile, val reviewed: Boolean) {
    val path: String get() = file.path
}

data class ReviewGroup(val chatId: String, val title: String, val directory: String, val status: Status, val files: List<ReviewFile>) {
    enum class Status {
        /** A current answer: [files] can be counted. */
        CURRENT,

        /** The computer has not answered for this chat yet. */
        UNKNOWN,
        CHECKING,

        /** The answer is that there is nothing git can compare. */
        NOT_REPOSITORY,
    }

    val pending: List<ReviewFile> get() = if (status == Status.CURRENT) files.filter { !it.reviewed } else emptyList()
}

/** The files across all open chats that await a look, grouped by chat. */
data class ReviewQueue(val groups: List<ReviewGroup>) {
    /** Chats worth a row: files to show, or no answer yet. */
    val visible: List<ReviewGroup>
        get() = groups.filter { it.files.isNotEmpty() || (it.status != ReviewGroup.Status.CURRENT && it.status != ReviewGroup.Status.NOT_REPOSITORY) }

    val pendingFileCount: Int get() = groups.sumOf { it.pending.size }
    val pendingChatCount: Int get() = groups.count { it.pending.isNotEmpty() }
    val added: Int get() = groups.sumOf { group -> group.pending.sumOf { it.file.added } }
    val removed: Int get() = groups.sumOf { group -> group.pending.sumOf { it.file.removed } }

    /** True while an answer is still awaited and nothing is pending, so the card can hold its place. */
    val checking: Boolean get() = pendingFileCount == 0 && groups.any { it.status == ReviewGroup.Status.CHECKING || it.status == ReviewGroup.Status.UNKNOWN }

    companion object {
        fun of(sources: List<ReviewSource>, marks: ReviewMarks): ReviewQueue = ReviewQueue(
            sources.map { source ->
                val report = source.report
                val status = when {
                    report == null -> if (source.loading) ReviewGroup.Status.CHECKING else ReviewGroup.Status.UNKNOWN
                    report.isRepository -> ReviewGroup.Status.CURRENT
                    else -> ReviewGroup.Status.NOT_REPOSITORY
                }
                val files = report?.files.orEmpty().sortedBy { it.path.lowercase() }.map { ReviewFile(it, marks.isReviewed(it, source.chatId)) }
                ReviewGroup(source.chatId, source.title, source.directory, status, files)
            },
        )
    }
}

/** When to ask the computer for a chat's changes again, so the list stays fresh without a request per redraw. */
class ReviewRefreshPolicy {
    enum class Reason { HUB_APPEARED, TURN_FINISHED }

    private val askedAt = HashMap<String, Long>()

    /** The chats to ask now; they are recorded as asked. */
    fun chatsToAsk(chats: List<String>, reason: Reason, nowMillis: Long): List<String> {
        val interval = if (reason == Reason.TURN_FINISHED) TURN_INTERVAL else APPEAR_INTERVAL
        val due = chats.filter { chat -> askedAt[chat]?.let { nowMillis - it >= interval } ?: true }
        due.forEach { askedAt[it] = nowMillis }
        return due
    }

    fun forgetExcept(live: Set<String>) {
        askedAt.keys.retainAll(live)
    }

    private companion object {
        const val APPEAR_INTERVAL = 30_000L

        /** A finished turn is the moment files change, so it asks sooner, but not twice in a burst. */
        const val TURN_INTERVAL = 3_000L
    }
}
