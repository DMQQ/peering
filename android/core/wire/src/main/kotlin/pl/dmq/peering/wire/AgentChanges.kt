package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.decodeFromJsonElement

/** How one file differs from the last commit. */
@Serializable
enum class AgentChangeKind {
    @SerialName("modified")
    MODIFIED,

    @SerialName("added")
    ADDED,

    @SerialName("deleted")
    DELETED,

    /** Not tracked by git yet: the whole file is new. */
    @SerialName("untracked")
    UNTRACKED,
}

/** One file git reports as changed under a session's folder. [diff] is absent for a file with no text to show. */
@Serializable
data class AgentChangedFile(
    val path: String,
    val kind: AgentChangeKind,
    val added: Int,
    val removed: Int,
    val diff: String? = null,
)

/** Where a session's folder stands on its branch. [head] is absent on a detached HEAD, [upstream] when none is set. */
@Serializable
data class AgentGitBranch(
    val head: String? = null,
    val upstream: String? = null,
    val remote: String? = null,
    val mergeRef: String? = null,
    val ahead: Int = 0,
    val behind: Int = 0,
)

/** What the computer found under a session's folder. [isRepository] is false when git could not run; [message] says why. */
@Serializable
data class AgentChangesReport(
    val isRepository: Boolean,
    val files: List<AgentChangedFile> = emptyList(),
    val paths: List<String> = emptyList(),
    val truncated: Boolean = false,
    val message: String? = null,
    val branch: AgentGitBranch? = null,
) {
    companion object {
        fun failure(message: String) = AgentChangesReport(isRepository = false, message = message)
    }
}

@Serializable
enum class AgentGitOperation {
    @SerialName("commit")
    COMMIT,

    @SerialName("push")
    PUSH,
}

/** How a commit or a push ended, with git's own words where it had any. */
@Serializable
data class AgentGitResult(
    val operation: AgentGitOperation,
    val succeeded: Boolean,
    val message: String,
)

/** The report, or null when the phone cannot read it: an unreadable answer must not fail the other events. */
fun AgentEvent.Changes.decoded(): AgentChangesReport? =
    runCatching { WireJson.decodeFromJsonElement<AgentChangesReport>(report) }.getOrNull()

fun AgentEvent.GitResult.decoded(): AgentGitResult? =
    runCatching { WireJson.decodeFromJsonElement<AgentGitResult>(result) }.getOrNull()
