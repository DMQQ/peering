package pl.dmq.peering.feature.agents

import kotlin.math.roundToLong
import pl.dmq.peering.session.agent.TranscriptRow
import pl.dmq.peering.wire.AgentTurnSummary

data class TranscriptUi(
    val sessionID: String?,
    val rows: List<TranscriptRow>,
    val queuedPrompts: List<String>,
    val expandedToolIDs: Set<Long>,
    val following: Boolean,
    val unseenRows: Int,
    val truncatedAtFront: Boolean,
    val loadingHistory: Boolean,
    val working: Boolean,
)

enum class TurnStatus {
    DONE,
    STOPPED,
    FAILED,
}

/** A finished turn as the pill shows it. Absent fields stay null: the CLI did not report them. */
data class TurnSummaryUi(
    val status: TurnStatus,
    val durationSeconds: Long?,
    val costUSD: Double?,
    val inputTokens: Long?,
    val outputTokens: Long?,
) {
    companion object {
        fun of(summary: AgentTurnSummary): TurnSummaryUi = TurnSummaryUi(
            status = when {
                !summary.ok -> TurnStatus.FAILED
                summary.stopped -> TurnStatus.STOPPED
                else -> TurnStatus.DONE
            },
            durationSeconds = summary.duration?.roundToLong(),
            costUSD = summary.costUSD,
            inputTokens = summary.inputTokens,
            outputTokens = summary.outputTokens,
        )
    }
}
