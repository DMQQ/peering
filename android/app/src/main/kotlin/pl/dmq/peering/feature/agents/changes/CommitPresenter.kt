package pl.dmq.peering.feature.agents.changes

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.agent.changes.CommitDraft
import pl.dmq.peering.session.agent.changes.CommitSelection
import pl.dmq.peering.session.agent.changes.PushBlock
import pl.dmq.peering.session.agent.changes.PushOffer
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentGitOperation
import pl.dmq.peering.wire.AgentGitResult

data class CommitFileUi(
    val path: String,
    val kind: AgentChangeKind,
    val added: Int,
    val removed: Int,
    val chosen: Boolean,
)

data class CommitUi(
    val files: List<CommitFileUi> = emptyList(),
    val chosenCount: Int = 0,
    val message: String = "",
    val branch: String? = null,
    val busy: AgentGitOperation? = null,
    val result: AgentGitResult? = null,
    val push: PushOffer = PushOffer.Blocked(PushBlock.UNREADABLE),
) {
    val canCommit: Boolean get() = busy == null && chosenCount > 0 && message.isNotBlank()
}

/** The commit sheet of one chat: which files go in, the message, and the push that follows. The computer decides what git runs. */
class CommitPresenter(
    private val port: AgentsPort,
    private val sessionID: String,
    scope: CoroutineScope,
) {
    private val selection = MutableStateFlow(CommitSelection())
    private val typed = MutableStateFlow<String?>(null)

    val ui: StateFlow<CommitUi> = combine(port.changes, selection, typed) { changes, chosen, text -> derive(changes, chosen, text) }
        .stateIn(scope, SharingStarted.Eagerly, derive(port.changes.value, selection.value, typed.value))

    init {
        port.changes
            .map { it[sessionID]?.gitResult }
            .distinctUntilChanged()
            .onEach { result ->
                if (result?.operation == AgentGitOperation.COMMIT && result.succeeded) {
                    selection.value = CommitSelection()
                    typed.value = null
                }
            }
            .launchIn(scope)
    }

    fun toggle(path: String) {
        val file = port.changes.value[sessionID]?.report?.files?.firstOrNull { it.path == path } ?: return
        selection.update { it.toggle(file) }
    }

    fun editMessage(text: String) {
        typed.value = text
    }

    /** Sends the chosen files with the message; nothing goes while a commit or push runs or the message is blank. */
    fun commit() {
        val current = ui.value
        if (!current.canCommit) return
        port.commitChanges(sessionID, current.files.filter { it.chosen }.map { it.path }, current.message.trim())
    }

    fun push() {
        val current = ui.value
        if (current.busy != null || current.push !is PushOffer.Ready) return
        port.pushChanges(sessionID)
    }

    private fun derive(changes: AgentChangesByChat, chosen: CommitSelection, text: String?): CommitUi {
        val state = changes[sessionID]
        val report = state?.report
        val files = report?.files.orEmpty()
        val picked = chosen.chosen(files)
        return CommitUi(
            files = files.map { CommitFileUi(it.path, it.kind, it.added, it.removed, chosen.isChosen(it)) },
            chosenCount = picked.size,
            message = text ?: CommitDraft.message(picked),
            branch = report?.branch?.head,
            busy = state?.gitBusy,
            result = state?.gitResult,
            push = PushOffer.of(report?.branch),
        )
    }
}
