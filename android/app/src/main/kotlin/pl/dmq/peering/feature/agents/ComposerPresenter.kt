package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.ComposerDraft
import pl.dmq.peering.session.agent.ComposerDrafts
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentSessionState

/**
 * The text box under the selected chat. Each chat keeps its own draft, saved through [store] on every change. The
 * action follows the turn: while one runs, a send queues behind it, and an empty box turns the button into a stop.
 */
class ComposerPresenter(
    private val port: AgentsPort,
    private val store: ComposerDraftStore,
    private val chats: StateFlow<AgentChatState>,
    private val modelPickerSupported: Boolean,
    scope: CoroutineScope,
) {
    private val drafts = MutableStateFlow(store.load())

    val ui: StateFlow<ComposerUi> = combine(chats, drafts) { chatState, saved -> derive(chatState, saved) }
        .stateIn(scope, SharingStarted.Eagerly, derive(chats.value, drafts.value))

    fun onTextChanged(text: String) = editSelected { it.copy(text = text) }

    fun attach(path: String) = editSelected { it.copy(attachedPaths = it.attachedPaths + path) }

    fun detach(index: Int) = editSelected { draft ->
        if (index in draft.attachedPaths.indices) draft.copy(attachedPaths = draft.attachedPaths.filterIndexed { i, _ -> i != index }) else draft
    }

    fun send() {
        val current = ui.value
        val sessionID = current.sessionID ?: return
        if (!current.actionEnabled || current.action == ComposerAction.STOP) return
        val draft = ComposerDraft(text = current.text, attachedPaths = current.attachedPaths)
        if (!draft.canSend(isUploading = false)) return
        port.prompt(sessionID, draft.toPrompt())
        saveDraft(sessionID, ComposerDraft())
    }

    fun stop() {
        val sessionID = ui.value.sessionID ?: return
        if (ui.value.action == ComposerAction.STOP) port.interrupt(sessionID)
    }

    fun setPermissionMode(mode: AgentPermissionMode) {
        val current = ui.value
        val sessionID = current.sessionID ?: return
        if (mode in current.permissionModes) port.setPermissionMode(sessionID, mode)
    }

    /** A null [model] chooses the CLI's default. Nothing is sent when the Mac did not declare the picker. */
    fun setModel(model: String?) {
        val current = ui.value
        val sessionID = current.sessionID ?: return
        if (!modelPickerSupported) return
        if (model == null || model in current.modelChoices) port.setModel(sessionID, model)
    }

    private fun editSelected(change: (ComposerDraft) -> ComposerDraft) {
        val sessionID = chats.value.selectedSessionID ?: return
        val updated = change(drafts.value.draftFor(sessionID))
        saveDraft(sessionID, updated)
    }

    private fun saveDraft(sessionID: String, draft: ComposerDraft) {
        val next = drafts.value.withDraft(sessionID, draft)
        drafts.update { next }
        store.save(next)
    }

    private fun derive(chatState: AgentChatState, saved: ComposerDrafts): ComposerUi {
        val session = chatState.selected
        val draft = session?.let { saved.draftFor(it.id) } ?: ComposerDraft()
        val state = session?.state
        val working = state == AgentSessionState.WORKING || state == AgentSessionState.AWAITING_APPROVAL
        val canSend = draft.canSend(isUploading = false)
        val action = when {
            working && !canSend -> ComposerAction.STOP
            working -> ComposerAction.QUEUE
            else -> ComposerAction.SEND
        }
        val modes = session?.info?.permissionModes.orEmpty()
        return ComposerUi(
            sessionID = session?.id,
            agentID = session?.info?.agentID,
            text = draft.text,
            attachedPaths = draft.attachedPaths,
            action = action,
            actionEnabled = session != null && (action == ComposerAction.STOP || canSend),
            permissionMode = session?.info?.permissionMode ?: modes.firstOrNull(),
            permissionModes = modes,
            model = session?.info?.model,
            modelChoices = if (modelPickerSupported) session?.info?.modelChoices.orEmpty() else emptyList(),
        )
    }
}
