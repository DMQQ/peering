package pl.dmq.peering.session.agent.changes

import pl.dmq.peering.wire.AgentChangesReport
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentGitOperation
import pl.dmq.peering.wire.AgentGitResult
import pl.dmq.peering.wire.decoded

/** What the phone knows of one chat's folder in git: the last report, the answer being waited for, and the last commit or push. */
data class AgentChangesState(
    val report: AgentChangesReport? = null,
    val loading: Boolean = false,
    val gitBusy: AgentGitOperation? = null,
    val gitResult: AgentGitResult? = null,
)

typealias AgentChangesByChat = Map<String, AgentChangesState>

/** Folds the computer's git answers into the per-chat state. Pure: the caller decides what to send. */
internal object AgentChangesReducer {
    fun askedForChanges(all: AgentChangesByChat, sessionID: String): AgentChangesByChat =
        all.update(sessionID) { it.copy(loading = true) }

    /** Null when a commit or push is already running for this chat: only one goes at a time. */
    fun askedToCommit(all: AgentChangesByChat, sessionID: String): AgentChangesByChat? =
        startGit(all, sessionID, AgentGitOperation.COMMIT)

    fun askedToPush(all: AgentChangesByChat, sessionID: String): AgentChangesByChat? =
        startGit(all, sessionID, AgentGitOperation.PUSH)

    /** Returns null for an event that is not about changes, so the caller can pass it on. */
    fun onEvent(all: AgentChangesByChat, event: AgentEvent): AgentChangesByChat? = when (event) {
        is AgentEvent.Changes -> {
            val report = event.decoded()
            all.update(event.sessionID) { it.copy(report = report ?: it.report, loading = false) }
        }
        is AgentEvent.GitResult -> {
            val result = event.decoded()
            all.update(event.sessionID) { it.copy(gitBusy = null, gitResult = result ?: it.gitResult) }
        }
        else -> null
    }

    /** The computer refused a request about this chat. Null when nothing was waiting, so the failure is shown elsewhere. */
    fun refused(all: AgentChangesByChat, sessionID: String, message: String): AgentChangesByChat? {
        val state = all[sessionID] ?: return null
        if (!state.loading && state.gitBusy == null) return null
        val report = if (state.loading && state.report == null) AgentChangesReport.failure(message) else state.report
        val result = state.gitBusy?.let { AgentGitResult(it, succeeded = false, message = message) } ?: state.gitResult
        return all + (sessionID to state.copy(report = report, loading = false, gitBusy = null, gitResult = result))
    }

    fun forget(all: AgentChangesByChat, sessionID: String): AgentChangesByChat = all - sessionID

    private fun startGit(all: AgentChangesByChat, sessionID: String, operation: AgentGitOperation): AgentChangesByChat? {
        if (all[sessionID]?.gitBusy != null) return null
        return all.update(sessionID) { it.copy(gitBusy = operation, gitResult = null) }
    }

    private inline fun AgentChangesByChat.update(
        sessionID: String,
        change: (AgentChangesState) -> AgentChangesState,
    ): AgentChangesByChat = this + (sessionID to change(this[sessionID] ?: AgentChangesState()))
}
