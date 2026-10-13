package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * Requests for terminals and the file browser. Byte fields travel as padded base64 text; the `...Bytes`
 * accessors decode them. Cases that need a newer Mac declaration are named in their KDoc.
 */
@Serializable(with = TerminalRequestSerializer::class)
sealed class TerminalRequest {
    @Serializable
    data object ListTerminals : TerminalRequest()

    /** Sent only to a Mac that declared `supportsAgentList`. */
    @Serializable
    data object ListAgents : TerminalRequest()

    @Serializable
    data object Create : TerminalRequest()

    @Serializable
    data class Input(val sessionID: String, val data: String) : TerminalRequest() {
        val dataBytes: ByteArray get() = data.fromBase64()
    }

    @Serializable
    data class Resize(val sessionID: String, val columns: Int, val rows: Int) : TerminalRequest()

    @Serializable
    data class Rename(val sessionID: String, val name: String) : TerminalRequest()

    @Serializable
    data class Retitle(val sessionID: String, val command: String) : TerminalRequest()

    @Serializable
    data class Close(val sessionID: String) : TerminalRequest()

    /** Sent only to a Mac that declared `supportsFileBrowser`. */
    @Serializable
    data class StartBrowser(val id: String) : TerminalRequest()

    /** A null [path] means the Mac's home folder; the answer carries the path it resolved to. */
    @Serializable
    data class ListDirectory(val sessionID: String, val path: String? = null) : TerminalRequest()

    @Serializable
    data class ReadFile(val sessionID: String, val path: String) : TerminalRequest()

    @Serializable
    data class ReadRange(val sessionID: String, val path: String, val offset: Long) : TerminalRequest()

    @Serializable
    data class ArchiveFolder(val sessionID: String, val path: String) : TerminalRequest()

    @Serializable
    data class BeginWrite(val sessionID: String, val path: String, val totalBytes: Long) : TerminalRequest()

    @Serializable
    data class WriteChunk(
        val sessionID: String,
        val path: String,
        val data: String,
        val isLast: Boolean,
    ) : TerminalRequest() {
        val dataBytes: ByteArray get() = data.fromBase64()
    }

    @Serializable
    data class ChangeFile(val sessionID: String, val operation: RemoteFileOperation) : TerminalRequest()

    /** The phone's APNs device token; [token] is its base64 form. */
    @Serializable
    data class RegisterPushToken(@SerialName("_0") val token: String) : TerminalRequest() {
        val tokenBytes: ByteArray get() = token.fromBase64()
    }

    fun toJson(): String = WireJson.encodeToString(TerminalRequestSerializer, this)

    companion object {
        fun parse(text: String): TerminalRequest = WireJson.decodeFromString(TerminalRequestSerializer, text)
    }
}

internal object TerminalRequestSerializer : SwiftCaseSerializer<TerminalRequest>() {
    private val cases: List<UnionCase<TerminalRequest>> = listOf(
        unionCase<TerminalRequest, TerminalRequest.ListTerminals>("list"),
        unionCase<TerminalRequest, TerminalRequest.ListAgents>("agents"),
        unionCase<TerminalRequest, TerminalRequest.Create>("create"),
        unionCase<TerminalRequest, TerminalRequest.Input>("input"),
        unionCase<TerminalRequest, TerminalRequest.Resize>("resize"),
        unionCase<TerminalRequest, TerminalRequest.Rename>("rename"),
        unionCase<TerminalRequest, TerminalRequest.Retitle>("retitle"),
        unionCase<TerminalRequest, TerminalRequest.Close>("close"),
        unionCase<TerminalRequest, TerminalRequest.StartBrowser>("startBrowser"),
        unionCase<TerminalRequest, TerminalRequest.ListDirectory>("listDirectory"),
        unionCase<TerminalRequest, TerminalRequest.ReadFile>("readFile"),
        unionCase<TerminalRequest, TerminalRequest.ReadRange>("readRange"),
        unionCase<TerminalRequest, TerminalRequest.ArchiveFolder>("archiveFolder"),
        unionCase<TerminalRequest, TerminalRequest.BeginWrite>("beginWrite"),
        unionCase<TerminalRequest, TerminalRequest.WriteChunk>("writeChunk"),
        unionCase<TerminalRequest, TerminalRequest.ChangeFile>("changeFile"),
        unionCase<TerminalRequest, TerminalRequest.RegisterPushToken>("registerPushToken"),
    )

    override fun encodeCase(value: TerminalRequest): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): TerminalRequest = decodeUnion(cases, json)
}
