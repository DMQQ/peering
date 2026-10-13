package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.ServerHello

/** What the host declared for agent chats. Each flag gates the requests and the events of one feature. */
data class AgentCapabilities(
    val chat: Boolean = false,
    val modelPicker: Boolean = false,
    val permissionModes: Boolean = false,
    val usage: Boolean = false,
    val sessionImport: Boolean = false,
    val pause: Boolean = false,
) {
    /** Model, permission and usage events are applied only when the host declared the feature they report. */
    fun admits(event: AgentEvent): Boolean = when (event) {
        is AgentEvent.ModelChanged -> modelPicker
        is AgentEvent.PermissionModeChanged -> permissionModes
        is AgentEvent.UsageChanged -> usage
        else -> true
    }

    companion object {
        fun declaredBy(hello: ServerHello): AgentCapabilities = AgentCapabilities(
            chat = hello.supportsAgentChat == true,
            modelPicker = hello.supportsAgentModelPicker == true,
            permissionModes = hello.supportsAgentPermissionModes == true,
            usage = hello.supportsAgentUsage == true,
            sessionImport = hello.supportsAgentSessionImport == true,
            pause = hello.supportsAgentPause == true,
        )

        /** A host from before the declaration chats with Claude Code and Codex only. */
        fun declaredAgents(hello: ServerHello): List<String> = hello.agentChatAgents ?: listOf("claude", "codex")
    }
}
