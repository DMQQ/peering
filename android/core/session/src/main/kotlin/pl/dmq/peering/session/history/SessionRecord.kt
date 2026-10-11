package pl.dmq.peering.session.history

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** One connection to a Mac, from the moment it was asked for until it ended. Times are epoch milliseconds. */
@Serializable
data class SessionRecord(
    val id: Long,
    val hostId: String,
    val hostName: String,
    val startedAt: Long,
    val endedAt: Long? = null,
    val path: Path,
    val reason: EndReason? = null,
) {
    @Serializable
    enum class Path {
        @SerialName("lan") LAN,
        @SerialName("relay") RELAY,
        @SerialName("direct") DIRECT,
    }

    @Serializable
    enum class EndReason {
        @SerialName("userEnded") USER_ENDED,
        @SerialName("hostStopped") HOST_STOPPED,
        @SerialName("connectionLost") CONNECTION_LOST,
        @SerialName("failed") FAILED,
    }
}
