package pl.dmq.peering.feature.agents.changes

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.agent.changes.DiffLine
import pl.dmq.peering.session.agent.changes.DiffLineKind
import pl.dmq.peering.session.agent.changes.ReviewComment
import pl.dmq.peering.session.agent.changes.ReviewPrompt
import pl.dmq.peering.session.agent.changes.ReviewPromptWords
import pl.dmq.peering.wire.AgentChangeKind

data class ChangeEntryUi(
    val path: String,
    val name: String,
    val folder: String,
    val kind: AgentChangeKind,
    val added: Int,
    val removed: Int,
    val diff: String?,
    val commentCount: Int,
)

data class ChangesUi(
    val entries: List<ChangeEntryUi> = emptyList(),
    val added: Int = 0,
    val removed: Int = 0,
    /** No answer from the computer yet. */
    val waiting: Boolean = true,
    val message: String? = null,
    val truncated: Boolean = false,
    val canCommit: Boolean = false,
    val comments: List<ReviewComment> = emptyList(),
)

/** One chat's Changes screen: the files git reports, and the comments the reader has written so far. */
class ChangesPresenter(
    private val port: AgentsPort,
    private val sessionID: String,
    scope: CoroutineScope,
) {
    private val comments = MutableStateFlow<List<ReviewComment>>(emptyList())
    private var nextCommentID = 1L

    val ui: StateFlow<ChangesUi> = combine(port.changes, comments) { changes, written -> derive(changes, written) }
        .stateIn(scope, SharingStarted.Eagerly, derive(port.changes.value, comments.value))

    fun refresh() = port.loadChanges(sessionID)

    fun entry(path: String): ChangeEntryUi? = ui.value.entries.firstOrNull { it.path == path }

    fun commentsOn(path: String): List<ReviewComment> = ui.value.comments.filter { it.path == path }

    /** A remark on [line] of [path], or on the whole file when [line] is null. Blank text is dropped. */
    fun addComment(path: String, text: String, line: DiffLine? = null) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val comment = ReviewComment(
            id = nextCommentID++,
            path = path,
            text = trimmed,
            line = line?.commentNumber,
            onRemovedLine = line?.kind == DiffLineKind.REMOVED,
            quote = line?.text,
        )
        comments.update { it + comment }
    }

    fun removeComment(id: Long) = comments.update { list -> list.filterNot { it.id == id } }

    /** Sends every comment to the agent as one prompt and clears them; false when there was nothing to send. */
    fun sendReview(words: ReviewPromptWords): Boolean {
        val written = comments.value
        if (written.isEmpty()) return false
        port.prompt(sessionID, ReviewPrompt.text(written, words))
        comments.value = emptyList()
        return true
    }

    private fun derive(changes: AgentChangesByChat, written: List<ReviewComment>): ChangesUi {
        val report = changes[sessionID]?.report ?: return ChangesUi(comments = written)
        val counts = written.groupingBy { it.path }.eachCount()
        val entries = report.files.map { file ->
            ChangeEntryUi(
                path = file.path,
                name = file.path.substringAfterLast('/'),
                folder = file.path.substringBeforeLast('/', ""),
                kind = file.kind,
                added = file.added,
                removed = file.removed,
                diff = file.diff,
                commentCount = counts[file.path] ?: 0,
            )
        }
        return ChangesUi(
            entries = entries,
            added = entries.sumOf { it.added },
            removed = entries.sumOf { it.removed },
            waiting = false,
            message = report.message,
            truncated = report.truncated,
            canCommit = report.isRepository,
            comments = written,
        )
    }
}
