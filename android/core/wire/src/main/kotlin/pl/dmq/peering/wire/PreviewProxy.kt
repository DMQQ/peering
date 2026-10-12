package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** One HTTP header. A pair rather than a map because a response may repeat a name and order is the sender's. */
@Serializable
data class PreviewHeader(val name: String, val value: String)

/**
 * One HTTP request for a server on the computer's own loopback. There is no host: the computer always dials
 * 127.0.0.1, so nothing the phone sends can name another machine. [id] is chosen by the phone and echoed on every
 * event of the answer. [target] is the path and query, starting with a single `/`. [body] is base64.
 */
@Serializable
data class PreviewProxyRequest(
    val id: Long,
    val port: Int,
    val method: String,
    val target: String,
    val headers: List<PreviewHeader> = emptyList(),
    val body: String? = null,
)

@Serializable(with = PreviewProxyCommandSerializer::class)
sealed class PreviewProxyCommand {
    @Serializable
    data class Fetch(@SerialName("_0") val request: PreviewProxyRequest) : PreviewProxyCommand()

    /** The page stopped waiting; the computer drops the transfer. */
    @Serializable
    data class Cancel(val id: Long) : PreviewProxyCommand()

    fun toJson(): String = WireJson.encodeToString(PreviewProxyCommandSerializer, this)
}

internal object PreviewProxyCommandSerializer : SwiftCaseSerializer<PreviewProxyCommand>() {
    private val cases: List<UnionCase<PreviewProxyCommand>> = listOf(
        unionCase<PreviewProxyCommand, PreviewProxyCommand.Fetch>("fetch"),
        unionCase<PreviewProxyCommand, PreviewProxyCommand.Cancel>("cancel"),
    )

    override fun encodeCase(value: PreviewProxyCommand): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): PreviewProxyCommand = decodeUnion(cases, json)
}

/** Why a request got no answer. A closed set, so the phone can word each one and none carries a computer's details. */
@Serializable
enum class PreviewFailure {
    @SerialName("invalidRequest")
    INVALID_REQUEST,

    @SerialName("notAllowed")
    NOT_ALLOWED,

    @SerialName("notListening")
    NOT_LISTENING,

    @SerialName("timedOut")
    TIMED_OUT,

    @SerialName("tooLarge")
    TOO_LARGE,

    @SerialName("busy")
    BUSY,

    /** The phone's own link to the computer was gone before an answer came. */
    @SerialName("disconnected")
    DISCONNECTED,

    @SerialName("failed")
    FAILED,
}

/** The answer in pieces: a head, then bodies, then an end. */
@Serializable(with = PreviewProxyEventSerializer::class)
sealed class PreviewProxyEvent {
    abstract val id: Long

    /** Whether nothing more follows for this request. */
    val isFinal: Boolean get() = this is End || this is Failure

    @Serializable
    data class Head(override val id: Long, val status: Int, val headers: List<PreviewHeader> = emptyList()) : PreviewProxyEvent()

    /** [data] is base64. */
    @Serializable
    data class Body(override val id: Long, val data: String) : PreviewProxyEvent() {
        val bytes: ByteArray get() = data.fromBase64()
    }

    /** [truncated] says the body hit the computer's size limit and the rest was dropped. */
    @Serializable
    data class End(override val id: Long, val truncated: Boolean = false) : PreviewProxyEvent()

    @Serializable
    data class Failure(override val id: Long, val reason: PreviewFailure) : PreviewProxyEvent()

    fun toJson(): String = WireJson.encodeToString(PreviewProxyEventSerializer, this)

    companion object {
        fun parse(text: String): PreviewProxyEvent = WireJson.decodeFromString(PreviewProxyEventSerializer, text)
    }
}

internal object PreviewProxyEventSerializer : SwiftCaseSerializer<PreviewProxyEvent>() {
    private val cases: List<UnionCase<PreviewProxyEvent>> = listOf(
        unionCase<PreviewProxyEvent, PreviewProxyEvent.Head>("head"),
        unionCase<PreviewProxyEvent, PreviewProxyEvent.Body>("body"),
        unionCase<PreviewProxyEvent, PreviewProxyEvent.End>("end"),
        unionCase<PreviewProxyEvent, PreviewProxyEvent.Failure>("failure"),
    )

    override fun encodeCase(value: PreviewProxyEvent): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): PreviewProxyEvent = decodeUnion(cases, json)
}
