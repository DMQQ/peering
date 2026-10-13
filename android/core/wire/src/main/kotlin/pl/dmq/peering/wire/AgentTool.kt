package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class AgentToolOption(
    val label: String,
    val detail: String? = null,
)

/** One question of an `AskUserQuestion` ask, with the choices offered for it. */
@Serializable
data class AgentQuestion(
    val header: String? = null,
    val question: String,
    val options: List<AgentToolOption>,
)

@Serializable
enum class AgentPlanStepStatus {
    @SerialName("pending")
    PENDING,

    @SerialName("inProgress")
    IN_PROGRESS,

    @SerialName("completed")
    COMPLETED;

    companion object {
        /** The CLIs spell the states `in_progress`, `inProgress` or `done`; anything unrecognised is still to do. */
        fun fromRaw(raw: String?): AgentPlanStepStatus = when (raw?.lowercase()?.replace("_", "")) {
            "inprogress", "active", "running" -> IN_PROGRESS
            "completed", "complete", "done" -> COMPLETED
            else -> PENDING
        }
    }
}

/** One line of an agent's own plan, as its to-do tool last wrote it. */
@Serializable
data class AgentPlanStep(
    val text: String,
    val status: AgentPlanStepStatus,
)

/**
 * One tool call in the shape both CLIs' events are normalised into. [name] stays open so a new tool
 * in a new CLI release draws a generic card instead of failing to decode.
 */
@Serializable
data class AgentToolCall(
    val id: String,
    val name: String,
    val title: String,
    val detail: String? = null,
    val filePath: String? = null,
    val diff: String? = null,
    val questions: List<AgentQuestion>? = null,
    val plan: List<AgentPlanStep>? = null,
)

/** What one finished turn cost. Each optional field is absent when the CLI does not report it. */
@Serializable
data class AgentTurnSummary(
    val ok: Boolean,
    val stopped: Boolean,
    val costUSD: Double? = null,
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    val duration: Double? = null,
    val model: String? = null,
)
