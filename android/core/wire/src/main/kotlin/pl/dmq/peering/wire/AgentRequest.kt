package pl.dmq.peering.wire

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * Requests an authenticated client sends for an agent chat session. Sent only to a Mac that declared
 * `supportsAgentChat`. The cases that need a newer declaration are named in their KDoc.
 */
@Serializable(with = AgentRequestSerializer::class)
sealed class AgentRequest {
    @Serializable
    data object ListSessions : AgentRequest()

    @Serializable
    data class History(val sessionID: String, val since: Long) : AgentRequest()

    @Serializable
    data class Start(val agentID: String, val directory: String? = null) : AgentRequest()

    @Serializable
    data class Prompt(val sessionID: String, val text: String) : AgentRequest()

    /** A second answer for the same [approvalID] is ignored by the Mac. */
    @Serializable
    data class Approval(
        val sessionID: String,
        val approvalID: String,
        val decision: AgentApprovalDecision,
    ) : AgentRequest()

    @Serializable
    data class Interrupt(val sessionID: String) : AgentRequest()

    @Serializable
    data class SetModel(val sessionID: String, val model: String? = null) : AgentRequest()

    @Serializable
    data class SetPermissionMode(val sessionID: String, val mode: AgentPermissionMode) : AgentRequest()

    @Serializable
    data class Close(val sessionID: String) : AgentRequest()

    @Serializable
    data class Browse(val path: String? = null) : AgentRequest()

    @Serializable
    data class Changes(val sessionID: String) : AgentRequest()

    @Serializable
    data class Commit(
        val sessionID: String,
        val paths: List<String>,
        val message: String,
    ) : AgentRequest()

    @Serializable
    data class Push(val sessionID: String) : AgentRequest()

    /** Sent only to a Mac that declared `supportsAgentSessionImport`. */
    @Serializable
    data object ListResumable : AgentRequest()

    /** Sent only to a Mac that declared `supportsAgentSessionImport`. */
    @Serializable
    data class Resume(val agentID: String, val cliSessionID: String) : AgentRequest()

    /** Sent only to a Mac that declared `supportsAgentPause`. */
    @Serializable
    data class Pause(val sessionID: String) : AgentRequest()

    fun toJson(): String = WireJson.encodeToString(AgentRequestSerializer, this)

    companion object {
        fun parse(text: String): AgentRequest = WireJson.decodeFromString(AgentRequestSerializer, text)
    }
}

internal object AgentRequestSerializer : SwiftCaseSerializer<AgentRequest>() {
    private val cases: List<UnionCase<AgentRequest>> = listOf(
        unionCase<AgentRequest, AgentRequest.ListSessions>("list"),
        unionCase<AgentRequest, AgentRequest.History>("history"),
        unionCase<AgentRequest, AgentRequest.Start>("start"),
        unionCase<AgentRequest, AgentRequest.Prompt>("prompt"),
        unionCase<AgentRequest, AgentRequest.Approval>("approval"),
        unionCase<AgentRequest, AgentRequest.Interrupt>("interrupt"),
        unionCase<AgentRequest, AgentRequest.SetModel>("setModel"),
        unionCase<AgentRequest, AgentRequest.SetPermissionMode>("setPermissionMode"),
        unionCase<AgentRequest, AgentRequest.Close>("close"),
        unionCase<AgentRequest, AgentRequest.Browse>("browse"),
        unionCase<AgentRequest, AgentRequest.Changes>("changes"),
        unionCase<AgentRequest, AgentRequest.Commit>("commit"),
        unionCase<AgentRequest, AgentRequest.Push>("push"),
        unionCase<AgentRequest, AgentRequest.ListResumable>("listResumable"),
        unionCase<AgentRequest, AgentRequest.Resume>("resume"),
        unionCase<AgentRequest, AgentRequest.Pause>("pause"),
    )

    override fun encodeCase(value: AgentRequest): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): AgentRequest = decodeUnion(cases, json)
}
