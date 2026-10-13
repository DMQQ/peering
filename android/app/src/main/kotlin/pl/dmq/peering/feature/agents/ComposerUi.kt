package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.files.UploadFailure
import pl.dmq.peering.wire.AgentPermissionMode

/** What the send button does: start a turn, queue behind the turn in flight, or stop it. */
enum class ComposerAction {
    SEND,
    QUEUE,
    STOP,
}

data class ComposerUi(
    val sessionID: String?,
    val agentID: String?,
    val text: String,
    val attachedPaths: List<String>,
    val directory: String,
    val canAttach: Boolean,
    /** The files that arrived on the computer, then the ones that did not. */
    val attachments: List<AttachmentChipUi>,
    /** The name of the file on its way, empty until the picked document has been read. */
    val uploadingName: String?,
    val action: ComposerAction,
    val actionEnabled: Boolean,
    val permissionMode: AgentPermissionMode?,
    val permissionModes: List<AgentPermissionMode>,
    val model: String?,
    val modelChoices: List<String>,
)

/** One chip in the tray over the composer. [failure] is set for a file that did not reach the computer. */
data class AttachmentChipUi(
    val key: String,
    val name: String,
    val thumbnailUri: String?,
    val failure: UploadFailure?,
    val failedKey: Long? = null,
)
