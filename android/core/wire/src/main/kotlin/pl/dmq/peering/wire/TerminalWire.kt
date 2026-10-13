package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A terminal as the Mac lists it. [columns], [rows] and [createdAt] are absent from a Mac too old to send them;
 * without the grid a client lays history out at 80x24.
 */
@Serializable
data class TerminalSessionInfo(
    val id: String,
    val name: String,
    val isRunning: Boolean,
    val columns: Int? = null,
    val rows: Int? = null,
    val createdAt: Double? = null,
)

@Serializable
enum class TerminalAttentionKind {
    @SerialName("confirmation")
    CONFIRMATION,

    @SerialName("password")
    PASSWORD,
}
