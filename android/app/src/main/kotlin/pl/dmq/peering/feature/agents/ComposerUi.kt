package pl.dmq.peering.feature.agents

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
    val action: ComposerAction,
    val actionEnabled: Boolean,
    val permissionMode: AgentPermissionMode?,
    val permissionModes: List<AgentPermissionMode>,
    val model: String?,
    val modelChoices: List<String>,
)
