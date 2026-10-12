package pl.dmq.peering.wire

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.decodeFromJsonElement

/**
 * A conversation a coding agent's CLI keeps on the computer, started there, that a chat can pick up. [modifiedAt] is
 * seconds since 2001-01-01. [mayBeOpenElsewhere] says it was written to a moment ago, so a terminal may still have it open.
 */
@Serializable
data class AgentResumableSession(
    val agentID: String,
    val cliSessionID: String,
    val directory: String,
    val title: String,
    val modifiedAt: Double,
    val mayBeOpenElsewhere: Boolean,
) {
    val id: String get() = "$agentID:$cliSessionID"
}

/** The listing's entries; one the phone cannot read is dropped rather than failing the rest. */
fun AgentEvent.Resumable.decoded(): List<AgentResumableSession> = sessions.mapNotNull { element ->
    runCatching { WireJson.decodeFromJsonElement<AgentResumableSession>(element) }.getOrNull()
}
