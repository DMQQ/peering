package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Events the Mac sends an agent chat client. The changes report, the git result and the resumable listing
 * stay raw JSON until their features decode them, so an unrelated decode cannot fail on them.
 */
@Serializable(with = AgentEventSerializer::class)
sealed class AgentEvent {
    @Serializable
    data class Snapshot(@SerialName("_0") val sessions: List<AgentSessionInfo>) : AgentEvent()

    @Serializable
    data class Created(@SerialName("_0") val session: AgentSessionInfo) : AgentEvent()

    @Serializable
    data class Stream(val sessionID: String, val event: AgentStreamEvent) : AgentEvent()

    /** A chunk of history. [truncatedAtFront] says the Mac no longer holds the start of the conversation. */
    @Serializable
    data class Replay(
        val sessionID: String,
        val events: List<AgentStreamEvent>,
        val isLast: Boolean,
        val truncatedAtFront: Boolean,
    ) : AgentEvent()

    @Serializable
    data class Directory(
        val path: String,
        val entries: List<RemoteDirectoryEntry>,
        val truncated: Boolean,
    ) : AgentEvent()

    @Serializable
    data class BrowseFailure(val path: String, val message: String) : AgentEvent()

    /** The Mac is waiting on something only someone at the Mac can answer; the listing follows once allowed. */
    @Serializable
    data class BrowseWaiting(val path: String, val message: String) : AgentEvent()

    @Serializable
    data class Changes(val sessionID: String, val report: JsonElement) : AgentEvent()

    @Serializable
    data class GitResult(val sessionID: String, val result: JsonElement) : AgentEvent()

    @Serializable
    data class Closed(val sessionID: String) : AgentEvent()

    /** [model] absent is the CLI's default. */
    @Serializable
    data class ModelChanged(val sessionID: String, val model: String? = null) : AgentEvent()

    @Serializable
    data class PermissionModeChanged(val sessionID: String, val mode: AgentPermissionMode) : AgentEvent()

    @Serializable
    data class UsageChanged(val sessionID: String, val usage: AgentUsage) : AgentEvent()

    /** [sessionID] is absent when the failure is not about one session. */
    @Serializable
    data class Failed(val sessionID: String? = null, val message: String) : AgentEvent()

    @Serializable
    data class Resumable(@SerialName("_0") val sessions: List<JsonElement>) : AgentEvent()

    fun toJson(): String = WireJson.encodeToString(AgentEventSerializer, this)

    companion object {
        fun parse(text: String): AgentEvent = WireJson.decodeFromString(AgentEventSerializer, text)
    }
}

internal object AgentEventSerializer : SwiftCaseSerializer<AgentEvent>() {
    private val cases: List<UnionCase<AgentEvent>> = listOf(
        unionCase<AgentEvent, AgentEvent.Snapshot>("snapshot"),
        unionCase<AgentEvent, AgentEvent.Created>("created"),
        unionCase<AgentEvent, AgentEvent.Stream>("stream"),
        unionCase<AgentEvent, AgentEvent.Replay>("replay"),
        unionCase<AgentEvent, AgentEvent.Directory>("directory"),
        unionCase<AgentEvent, AgentEvent.BrowseFailure>("browseFailure"),
        unionCase<AgentEvent, AgentEvent.BrowseWaiting>("browseWaiting"),
        unionCase<AgentEvent, AgentEvent.Changes>("changes"),
        unionCase<AgentEvent, AgentEvent.GitResult>("gitResult"),
        unionCase<AgentEvent, AgentEvent.Closed>("closed"),
        unionCase<AgentEvent, AgentEvent.ModelChanged>("modelChanged"),
        unionCase<AgentEvent, AgentEvent.PermissionModeChanged>("permissionModeChanged"),
        unionCase<AgentEvent, AgentEvent.UsageChanged>("usageChanged"),
        unionCase<AgentEvent, AgentEvent.Failed>("failed"),
        unionCase<AgentEvent, AgentEvent.Resumable>("resumable"),
    )

    override fun encodeCase(value: AgentEvent): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): AgentEvent = decodeUnion(cases, json)
}
