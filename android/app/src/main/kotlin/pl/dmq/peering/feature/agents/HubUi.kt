package pl.dmq.peering.feature.agents

/** The new-chat flow: pick an agent, then a folder for it. */
sealed interface NewChatStep {
    data object Closed : NewChatStep

    data object ChoosingAgent : NewChatStep

    data class ChoosingFolder(val agentID: String) : NewChatStep
}

data class HubUi(
    val sessions: List<SessionCard>,
    val selectedSessionID: String?,
    val agents: List<AgentOption>,
    val newChat: NewChatStep,
    val failure: String?,
    val recentFolders: List<String>,
)
