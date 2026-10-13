package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * Terminal state and byte output from the Mac. Output stays bytes (base64 here) because a PTY may split a
 * UTF-8 scalar between reads and emits ANSI control sequences by design.
 */
@Serializable(with = TerminalEventSerializer::class)
sealed class TerminalEvent {
    @Serializable
    data class Snapshot(@SerialName("_0") val terminals: List<TerminalSessionInfo>) : TerminalEvent()

    @Serializable
    data class Agents(val installed: List<String>) : TerminalEvent()

    @Serializable
    data class Created(@SerialName("_0") val terminal: TerminalSessionInfo) : TerminalEvent()

    @Serializable
    data class Renamed(@SerialName("_0") val terminal: TerminalSessionInfo) : TerminalEvent()

    @Serializable
    data class Output(val sessionID: String, val data: String) : TerminalEvent() {
        val dataBytes: ByteArray get() = data.fromBase64()
    }

    @Serializable
    data class Attention(
        val sessionID: String,
        val kind: TerminalAttentionKind,
        val message: String,
    ) : TerminalEvent()

    @Serializable
    data class CommandFinished(
        val sessionID: String,
        val command: String? = null,
        val duration: Double,
        val exitStatus: Int,
    ) : TerminalEvent()

    @Serializable
    data class Exited(val sessionID: String, val status: Int) : TerminalEvent()

    @Serializable
    data class Closed(val sessionID: String) : TerminalEvent()

    /** Sorted by the Mac (folders first, then names). [truncated] says the entry cap was reached. */
    @Serializable
    data class Directory(
        val sessionID: String,
        val path: String,
        val entries: List<RemoteDirectoryEntry>,
        val truncated: Boolean,
    ) : TerminalEvent()

    /** One piece of a file's contents. [totalBytes] is the size on disk; offset plus length says whether the file was cut short. */
    @Serializable
    data class FileContents(
        val sessionID: String,
        val path: String,
        val kind: RemoteFileKind,
        val offset: Long,
        val totalBytes: Long,
        val data: String,
        val isLast: Boolean,
    ) : TerminalEvent() {
        val dataBytes: ByteArray get() = data.fromBase64()
    }

    /** One piece of a download. Pieces may arrive out of order, which is why each names its [offset]. */
    @Serializable
    data class FileRange(
        val sessionID: String,
        val path: String,
        val offset: Long,
        val totalBytes: Long,
        val data: String,
    ) : TerminalEvent() {
        val dataBytes: ByteArray get() = data.fromBase64()
    }

    @Serializable
    data class ArchiveReady(
        val sessionID: String,
        val folder: String,
        val archivePath: String,
        val totalBytes: Long,
    ) : TerminalEvent()

    @Serializable
    data class TransferFailure(val sessionID: String, val path: String, val message: String) : TerminalEvent()

    @Serializable
    data class BrowseFailure(val sessionID: String, val path: String, val message: String) : TerminalEvent()

    @Serializable
    data class WroteFile(val sessionID: String, val path: String, val totalBytes: Long) : TerminalEvent()

    /** Unlike [BrowseFailure], which clears the panel: a failed save leaves the editor open on the user's text. */
    @Serializable
    data class WriteFailure(val sessionID: String, val path: String, val message: String) : TerminalEvent()

    /** [path] is echoed from the request. For a rename that is the old path. */
    @Serializable
    data class FileOperationDone(val sessionID: String, val path: String, val note: String) : TerminalEvent()

    @Serializable
    data class FileOperationFailure(val sessionID: String, val path: String, val message: String) : TerminalEvent()

    /** [sessionID] is absent when the failure is not about one terminal. */
    @Serializable
    data class Failed(val sessionID: String? = null, val message: String) : TerminalEvent()

    fun toJson(): String = WireJson.encodeToString(TerminalEventSerializer, this)

    companion object {
        fun parse(text: String): TerminalEvent = WireJson.decodeFromString(TerminalEventSerializer, text)
    }
}

internal object TerminalEventSerializer : SwiftCaseSerializer<TerminalEvent>() {
    private val cases: List<UnionCase<TerminalEvent>> = listOf(
        unionCase<TerminalEvent, TerminalEvent.Snapshot>("snapshot"),
        unionCase<TerminalEvent, TerminalEvent.Agents>("agents"),
        unionCase<TerminalEvent, TerminalEvent.Created>("created"),
        unionCase<TerminalEvent, TerminalEvent.Renamed>("renamed"),
        unionCase<TerminalEvent, TerminalEvent.Output>("output"),
        unionCase<TerminalEvent, TerminalEvent.Attention>("attention"),
        unionCase<TerminalEvent, TerminalEvent.CommandFinished>("commandFinished"),
        unionCase<TerminalEvent, TerminalEvent.Exited>("exited"),
        unionCase<TerminalEvent, TerminalEvent.Closed>("closed"),
        unionCase<TerminalEvent, TerminalEvent.Directory>("directory"),
        unionCase<TerminalEvent, TerminalEvent.FileContents>("fileContents"),
        unionCase<TerminalEvent, TerminalEvent.FileRange>("fileRange"),
        unionCase<TerminalEvent, TerminalEvent.ArchiveReady>("archiveReady"),
        unionCase<TerminalEvent, TerminalEvent.TransferFailure>("transferFailure"),
        unionCase<TerminalEvent, TerminalEvent.BrowseFailure>("browseFailure"),
        unionCase<TerminalEvent, TerminalEvent.WroteFile>("wroteFile"),
        unionCase<TerminalEvent, TerminalEvent.WriteFailure>("writeFailure"),
        unionCase<TerminalEvent, TerminalEvent.FileOperationDone>("fileOperationDone"),
        unionCase<TerminalEvent, TerminalEvent.FileOperationFailure>("fileOperationFailure"),
        unionCase<TerminalEvent, TerminalEvent.Failed>("failed"),
    )

    override fun encodeCase(value: TerminalEvent): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): TerminalEvent = decodeUnion(cases, json)
}
