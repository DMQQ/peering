package pl.dmq.peering.feature.agents

import pl.dmq.peering.wire.AgentPermissionMode

/** Which explanation a permission mode carries. The wording differs for the CLI that can ask for approval. */
enum class PermissionDetail {
    ASKS_BEFORE_ACTING,
    EDITS_WITHOUT_ASKING,
    WORKS_INSIDE_FOLDER,
    PLANS_ONLY,
    REVIEWER_CHECKS,
    NEVER_ASKS,
}

object PermissionModeCopy {
    fun detail(mode: AgentPermissionMode, agentID: String?): PermissionDetail {
        val claude = agentID == CLAUDE_AGENT_ID
        return when (mode) {
            AgentPermissionMode.MANUAL -> PermissionDetail.ASKS_BEFORE_ACTING
            AgentPermissionMode.ACCEPT_EDITS -> if (claude) PermissionDetail.EDITS_WITHOUT_ASKING else PermissionDetail.WORKS_INSIDE_FOLDER
            AgentPermissionMode.PLAN -> PermissionDetail.PLANS_ONLY
            AgentPermissionMode.AUTO -> if (claude) PermissionDetail.REVIEWER_CHECKS else PermissionDetail.NEVER_ASKS
        }
    }

    private const val CLAUDE_AGENT_ID = "claude"
}
