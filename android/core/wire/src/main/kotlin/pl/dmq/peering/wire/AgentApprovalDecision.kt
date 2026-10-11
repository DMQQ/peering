package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** The user's verdict on one approval prompt. [Choose] answers a question-style ask, one label per question, in order. */
@Serializable(with = AgentApprovalDecisionSerializer::class)
sealed class AgentApprovalDecision {
    @Serializable
    data object Allow : AgentApprovalDecision()

    @Serializable
    data object Deny : AgentApprovalDecision()

    @Serializable
    data class Choose(@SerialName("_0") val answers: List<String>) : AgentApprovalDecision()
}

internal object AgentApprovalDecisionSerializer : SwiftCaseSerializer<AgentApprovalDecision>() {
    private val cases: List<UnionCase<AgentApprovalDecision>> = listOf(
        unionCase<AgentApprovalDecision, AgentApprovalDecision.Allow>("allow"),
        unionCase<AgentApprovalDecision, AgentApprovalDecision.Deny>("deny"),
        unionCase<AgentApprovalDecision, AgentApprovalDecision.Choose>("choose"),
    )

    override fun encodeCase(value: AgentApprovalDecision): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): AgentApprovalDecision = decodeUnion(cases, json)
}
