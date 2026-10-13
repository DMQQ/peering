package pl.dmq.peering.feature.agents

/** The new-chat flow: pick an agent, then a folder for it. */
sealed interface NewChatStep {
    data object Closed : NewChatStep

    data object ChoosingAgent : NewChatStep

    data class ChoosingFolder(val agentID: String) : NewChatStep
}

/** A conversation started on the computer. [modifiedAtUnix] is seconds since the Unix epoch. */
data class ResumableCard(
    val id: String,
    val agentID: String,
    val agentName: String,
    val title: String,
    val directory: String,
    val modifiedAtUnix: Long,
    val openElsewhere: Boolean,
)

/** What one agent is doing across the open chats, for its card in the picker. [lastUsedUnix] is null when it has no chat. */
data class AgentUsage(val agentID: String, val working: Int, val needsYou: Int, val open: Int, val lastUsedUnix: Long?)

data class HubUi(
    val sessions: List<SessionCard>,
    val history: List<SessionCard>,
    val resumable: List<ResumableCard>,
    val canImport: Boolean,
    val selectedSessionID: String?,
    val agents: List<AgentOption>,
    val agentUsage: List<AgentUsage>,
    val selectedAgentID: String?,
    val newChat: NewChatStep,
    val failure: String?,
    val recentFolders: List<String>,
    /** True until the computer has answered the first listing of its conversations. */
    val loading: Boolean = false,
)
