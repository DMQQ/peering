package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** How freely an agent may act without asking. A session lists the modes its CLI supports in [AgentSessionInfo.permissionModes]. */
@Serializable
enum class AgentPermissionMode {
    @SerialName("manual")
    MANUAL,

    @SerialName("acceptEdits")
    ACCEPT_EDITS,

    @SerialName("plan")
    PLAN,

    @SerialName("auto")
    AUTO,
}

/** What a session is doing: a fact about the turn, not the process. */
@Serializable
enum class AgentSessionState {
    @SerialName("idle")
    IDLE,

    @SerialName("working")
    WORKING,

    @SerialName("awaitingApproval")
    AWAITING_APPROVAL,

    @SerialName("exited")
    EXITED,

    @SerialName("failed")
    FAILED,
}

/** One rate-limit window. [usedFraction] runs from 0 to 1; [resetsAt] is seconds since 2001-01-01. */
@Serializable
data class AgentUsageLimit(
    val label: String,
    val usedFraction: Double,
    val resetsAt: Double? = null,
)

/** What a session has used, as far as its CLI reports it. Fields a CLI does not report are absent, never guessed. */
@Serializable
data class AgentUsage(
    val contextUsedTokens: Long? = null,
    val contextWindowTokens: Long? = null,
    val inputTokens: Long,
    val cachedTokens: Long,
    val outputTokens: Long,
    val costUSD: Double? = null,
    val limits: List<AgentUsageLimit>,
)

/** A chat session as the Mac lists it. [id] is an uppercase UUID string; [createdAt] is seconds since 2001-01-01. */
@Serializable
data class AgentSessionInfo(
    val id: String,
    val agentID: String,
    val title: String,
    val directory: String,
    val state: AgentSessionState,
    val lastIndex: Long,
    val model: String? = null,
    val permissionMode: AgentPermissionMode? = null,
    val permissionModes: List<AgentPermissionMode>? = null,
    val modelChoices: List<String>? = null,
    val usage: AgentUsage? = null,
    val createdAt: Double,
)
