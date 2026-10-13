package pl.dmq.peering.wire

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** One thing that happened in an agent session. Clients apply an event only if its index exceeds the last applied. */
@Serializable
data class AgentStreamEvent(
    val index: Long,
    val payload: AgentStreamPayload,
)

@Serializable(with = AgentStreamPayloadSerializer::class)
sealed class AgentStreamPayload {
    @Serializable
    data class SessionReady(
        val agentID: String,
        val cliSessionID: String? = null,
        val model: String? = null,
        val directory: String,
    ) : AgentStreamPayload()

    @Serializable
    data class UserPrompt(val text: String) : AgentStreamPayload()

    @Serializable
    data object TurnStarted : AgentStreamPayload()

    @Serializable
    data class TextDelta(val text: String) : AgentStreamPayload()

    @Serializable
    data class TextFinal(val text: String) : AgentStreamPayload()

    @Serializable
    data class ToolStarted(val call: AgentToolCall) : AgentStreamPayload()

    /** [output] is truncated by the host; [truncated] says so. */
    @Serializable
    data class ToolFinished(
        val callID: String,
        val ok: Boolean,
        val output: String? = null,
        val truncated: Boolean,
    ) : AgentStreamPayload()

    @Serializable
    data class ApprovalRequested(
        val approvalID: String,
        val call: AgentToolCall,
        val reason: String? = null,
    ) : AgentStreamPayload()

    @Serializable
    data class ApprovalResolved(
        val approvalID: String,
        val decision: AgentApprovalDecision,
    ) : AgentStreamPayload()

    @Serializable
    data class TurnFinished(val summary: AgentTurnSummary) : AgentStreamPayload()

    @Serializable
    data class Notice(val text: String) : AgentStreamPayload()

    @Serializable
    data class Failure(val message: String) : AgentStreamPayload()

    @Serializable
    data class SessionExited(val status: Int) : AgentStreamPayload()

    /** Something a sub-agent did, filed under the `Task` call that spawned it. */
    @Serializable
    data class Child(
        val parentCallID: String,
        val event: AgentStreamPayload,
    ) : AgentStreamPayload()
}

internal object AgentStreamPayloadSerializer : SwiftCaseSerializer<AgentStreamPayload>() {
    private val cases: List<UnionCase<AgentStreamPayload>> = listOf(
        unionCase<AgentStreamPayload, AgentStreamPayload.SessionReady>("sessionReady"),
        unionCase<AgentStreamPayload, AgentStreamPayload.UserPrompt>("userPrompt"),
        unionCase<AgentStreamPayload, AgentStreamPayload.TurnStarted>("turnStarted"),
        unionCase<AgentStreamPayload, AgentStreamPayload.TextDelta>("textDelta"),
        unionCase<AgentStreamPayload, AgentStreamPayload.TextFinal>("textFinal"),
        unionCase<AgentStreamPayload, AgentStreamPayload.ToolStarted>("toolStarted"),
        unionCase<AgentStreamPayload, AgentStreamPayload.ToolFinished>("toolFinished"),
        unionCase<AgentStreamPayload, AgentStreamPayload.ApprovalRequested>("approvalRequested"),
        unionCase<AgentStreamPayload, AgentStreamPayload.ApprovalResolved>("approvalResolved"),
        unionCase<AgentStreamPayload, AgentStreamPayload.TurnFinished>("turnFinished"),
        unionCase<AgentStreamPayload, AgentStreamPayload.Notice>("notice"),
        unionCase<AgentStreamPayload, AgentStreamPayload.Failure>("failure"),
        unionCase<AgentStreamPayload, AgentStreamPayload.SessionExited>("sessionExited"),
        unionCase<AgentStreamPayload, AgentStreamPayload.Child>("child"),
    )

    override fun encodeCase(value: AgentStreamPayload): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): AgentStreamPayload = decodeUnion(cases, json)
}
