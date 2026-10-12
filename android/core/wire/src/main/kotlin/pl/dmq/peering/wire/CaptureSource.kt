package pl.dmq.peering.wire

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/** What the host captures, by raw platform id, so the wire does not depend on any OS header. */
sealed class CaptureSource {
    abstract val stableId: String

    data class Display(val id: Long) : CaptureSource() {
        override val stableId: String get() = "display:$id"
    }

    data class Application(val pid: Int) : CaptureSource() {
        override val stableId: String get() = "application:$pid"
    }

    data class Window(val id: Long) : CaptureSource() {
        override val stableId: String get() = "window:$id"
    }

    data class Mosaic(val raw: JsonElement) : CaptureSource() {
        override val stableId: String get() = "mosaic"
    }

    fun toJson(): JsonObject = when (this) {
        is Display -> swiftCase("display", labelled(JsonPrimitive(id)))
        is Application -> swiftCase("application", labelled(JsonPrimitive(pid)))
        is Window -> swiftCase("window", labelled(JsonPrimitive(id)))
        is Mosaic -> swiftCase("mosaic", labelled(raw))
    }

    companion object {
        fun fromJson(json: JsonObject): CaptureSource {
            val (name, payload) = json.swiftCase()
            val value = payload["_0"] ?: throw SwiftEnumException("capture source $name has no value")
            return when (name) {
                "display" -> Display(WireJson.decodeFromJsonElement(Long.serializer(), value))
                "application" -> Application(WireJson.decodeFromJsonElement(Int.serializer(), value))
                "window" -> Window(WireJson.decodeFromJsonElement(Long.serializer(), value))
                "mosaic" -> Mosaic(value)
                else -> throw SwiftEnumException("unknown capture source case $name")
            }
        }

        private fun labelled(value: JsonElement): JsonObject = buildJsonObject { put("_0", value) }
    }
}

/** Writes and reads [CaptureSource] as its Swift case object, so it can sit inside another serialised model. */
object CaptureSourceSerializer : KSerializer<CaptureSource> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor

    override fun serialize(encoder: Encoder, value: CaptureSource) {
        encoder.encodeSerializableValue(JsonObject.serializer(), value.toJson())
    }

    override fun deserialize(decoder: Decoder): CaptureSource =
        CaptureSource.fromJson(decoder.decodeSerializableValue(JsonObject.serializer()))
}

/** A point in the captured source's own space: (0,0) top left, (1,1) bottom right. */
@Serializable
data class NormalizedPoint(val x: Double, val y: Double) {
    fun clamped(): NormalizedPoint = NormalizedPoint(unitInterval(x), unitInterval(y))

    private fun unitInterval(value: Double): Double = if (value.isNaN()) 0.0 else value.coerceIn(0.0, 1.0)
}

@Serializable
enum class CaptureSourceKind {
    @SerialName("display") DISPLAY,
    @SerialName("application") APPLICATION,
    @SerialName("window") WINDOW,
}

/** Real pixels, written as the two-element array `[width, height]`. */
data class PixelSize(val width: Double, val height: Double)

object PixelSizeSerializer : KSerializer<PixelSize> {
    private val delegate = ListSerializer(Double.serializer())

    override val descriptor: SerialDescriptor = delegate.descriptor

    override fun serialize(encoder: Encoder, value: PixelSize) {
        encoder.encodeSerializableValue(delegate, listOf(value.width, value.height))
    }

    override fun deserialize(decoder: Decoder): PixelSize {
        val values = decoder.decodeSerializableValue(delegate)
        if (values.size != 2) throw SwiftEnumException("pixelSize needs two numbers, found ${values.size}")
        return PixelSize(values[0], values[1])
    }
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class CaptureSourceDescriptor(
    val id: String,
    val kind: CaptureSourceKind,
    val title: String,
    val subtitle: String? = null,
    val bundleIdentifier: String? = null,
    val iconPNGData: String? = null,
    @Serializable(SourceThumbnailSerializer::class) val thumbnail: SourceThumbnail? = null,
    @Serializable(CaptureSourceSerializer::class) val source: CaptureSource,
    @Serializable(PixelSizeSerializer::class) val pixelSize: PixelSize,
    @EncodeDefault val isManagedVirtualDisplay: Boolean = false,
    @EncodeDefault val isVirtualDisplay: Boolean = false,
) {
    val iconPNGBytes: ByteArray? get() = iconPNGData?.fromBase64()
}

/** Every list may be absent on input. All four lists are always written, so an empty list is `[]`. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class CaptureCatalog(
    @EncodeDefault val displays: List<CaptureSourceDescriptor> = emptyList(),
    @EncodeDefault val applications: List<CaptureSourceDescriptor> = emptyList(),
    @EncodeDefault val windows: List<CaptureSourceDescriptor> = emptyList(),
    @EncodeDefault val installedApplications: List<JsonElement> = emptyList(),
    val spaceInfo: JsonElement? = null,
) {
    fun toJson(): String = WireJson.encodeToString(CaptureCatalog.serializer(), this)

    companion object {
        fun parse(text: String): CaptureCatalog = WireJson.decodeFromString(CaptureCatalog.serializer(), text)
    }
}
