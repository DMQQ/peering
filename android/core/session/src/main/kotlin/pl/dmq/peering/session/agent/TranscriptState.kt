package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.AgentSessionState

/**
 * A session's conversation rebuilt from its event stream.
 *
 * [needsHistory] is set when a live event arrived past a gap. Such an event is withheld, not applied, and the
 * caller asks for history since [lastIndex]; the replay clears the flag once its last chunk is applied.
 */
data class TranscriptState(
    val rows: List<TranscriptRow> = emptyList(),
    val sessionState: AgentSessionState = AgentSessionState.IDLE,
    val lastIndex: Long = 0,
    val truncatedAtFront: Boolean = false,
    val needsHistory: Boolean = false,
    internal val openReplyID: Long? = null,
    internal val nextRowID: Long = 1,
    /** Characters held in the rows, kept as they change so trimming never recounts on every event. */
    internal val approximateSize: Int = 0,
)
