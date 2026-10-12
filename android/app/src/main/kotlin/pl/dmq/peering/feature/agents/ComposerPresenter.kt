package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.agents.attach.AttachmentOutcome
import pl.dmq.peering.feature.agents.attach.AttachmentSender
import pl.dmq.peering.feature.agents.attach.AttachmentSource
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
    private val scope: CoroutineScope,
    private val attachments: AttachmentSender? = null,
) {
    private val drafts = MutableStateFlow(store.load())
    private val attaching = MutableStateFlow(AttachState())

    val ui: StateFlow<ComposerUi> = combine(chats, drafts, attaching) { chatState, saved, files -> derive(chatState, saved, files) }
        .stateIn(scope, SharingStarted.Eagerly, derive(chats.value, drafts.value, attaching.value))

    fun onTextChanged(text: String) = editSelected { it.copy(text = text) }

    fun attach(path: String) = editSelected { it.copy(attachedPaths = it.attachedPaths + path) }

    /**
     * Sends a picked file into the chat's folder on the computer and, once it is there, attaches its path to that
     * chat's draft. One file goes at a time, and none while the agent is working.
     */
    fun attach(source: AttachmentSource) {
        val sender = attachments ?: return
        val current = ui.value
        val sessionID = current.sessionID ?: return
        if (!current.canAttach || current.uploadingName != null) return
        attaching.update { it.copy(uploading = Uploading(sessionID, "")) }
        scope.launch {
            val outcome = sender.send(source, current.directory) { name ->
                attaching.update { files -> files.copy(uploading = files.uploading?.copy(name = name)) }
            }
            finishAttaching(sessionID, outcome)
        }
    }

    fun removeFailedAttachment(key: Long) = attaching.update { files -> files.copy(failed = files.failed.filterNot { it.key == key }) }

    private fun finishAttaching(sessionID: String, outcome: AttachmentOutcome) {
        when (outcome) {
            is AttachmentOutcome.Sent -> {
                attaching.update { files ->
                    files.copy(uploading = null, thumbnails = outcome.thumbnailUri?.let { files.thumbnails + (outcome.path to it) } ?: files.thumbnails)
                }
                editSession(sessionID) { it.copy(attachedPaths = it.attachedPaths + outcome.path) }
            }
            is AttachmentOutcome.Failed -> attaching.update { files ->
                files.copy(uploading = null, failed = files.failed + FailedAttachment(files.nextKey, sessionID, outcome.name, outcome.reason), nextKey = files.nextKey + 1)
            }
        }
    }

    fun detach(index: Int) = editSelected { draft ->
        if (index in draft.attachedPaths.indices) draft.copy(attachedPaths = draft.attachedPaths.filterIndexed { i, _ -> i != index }) else draft
    }

    fun send() {
        val current = ui.value
        val sessionID = current.sessionID ?: return
        if (!current.actionEnabled || current.action == ComposerAction.STOP) return
        val draft = ComposerDraft(text = current.text, attachedPaths = current.attachedPaths)
        if (!draft.canSend(isUploading = current.uploadingName != null)) return
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
        editSession(sessionID, change)
    }

    private fun editSession(sessionID: String, change: (ComposerDraft) -> ComposerDraft) {
        saveDraft(sessionID, change(drafts.value.draftFor(sessionID)))
    }

    private fun saveDraft(sessionID: String, draft: ComposerDraft) {
        val next = drafts.value.withDraft(sessionID, draft)
        drafts.update { next }
        store.save(next)
    }

    private fun derive(chatState: AgentChatState, saved: ComposerDrafts, files: AttachState): ComposerUi {
        val session = chatState.selected
        val draft = session?.let { saved.draftFor(it.id) } ?: ComposerDraft()
        val state = session?.state
        val working = state == AgentSessionState.WORKING || state == AgentSessionState.AWAITING_APPROVAL
        val uploadingHere = files.uploading?.takeIf { it.sessionID == session?.id }
        val canSend = draft.canSend(isUploading = uploadingHere != null)
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
            directory = session?.info?.directory.orEmpty(),
            canAttach = attachments != null && session != null && !working,
            attachments = draft.attachedPaths.map { path ->
                AttachmentChipUi(key = path, name = path.substringAfterLast('/'), thumbnailUri = files.thumbnails[path], failure = null)
            } + files.failed.filter { it.sessionID == session?.id }.map {
                AttachmentChipUi(key = "failed-${it.key}", name = it.name, thumbnailUri = null, failure = it.reason, failedKey = it.key)
            },
            uploadingName = uploadingHere?.name,
            action = action,
            actionEnabled = session != null && (action == ComposerAction.STOP || canSend),
            permissionMode = session?.info?.permissionMode ?: modes.firstOrNull(),
            permissionModes = modes,
            model = session?.info?.model,
            modelChoices = if (modelPickerSupported) session?.info?.modelChoices.orEmpty() else emptyList(),
        )
    }
}
