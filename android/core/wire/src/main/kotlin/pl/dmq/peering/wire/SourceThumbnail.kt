package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A JPEG picture of a source. [width] and [height] are pixels, so a tile can keep its shape before the image decodes. */
class SourceThumbnail(val width: Int, val height: Int, val jpegData: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is SourceThumbnail && width == other.width && height == other.height && jpegData.contentEquals(other.jpegData)

    override fun hashCode(): Int = 31 * (31 * width + height) + jpegData.contentHashCode()

    companion object {
        /** The host never sends more than this; a larger picture is refused rather than decoded. */
        const val MAXIMUM_BYTES = 32 * 1024
    }
}

/** Reads `{width, height, jpegData}`. A malformed or oversize picture reads as none, so one bad tile never costs the list. */
object SourceThumbnailSerializer : KSerializer<SourceThumbnail?> {
    override val descriptor: SerialDescriptor = JsonElement.serializer().descriptor

    override fun serialize(encoder: Encoder, value: SourceThumbnail?) {
        val element: JsonElement = if (value == null) {
            JsonNull
        } else {
            JsonObject(
                mapOf(
                    "width" to JsonPrimitive(value.width),
                    "height" to JsonPrimitive(value.height),
                    "jpegData" to JsonPrimitive(value.jpegData.toBase64()),
                ),
            )
        }
        encoder.encodeSerializableValue(JsonElement.serializer(), element)
    }

    override fun deserialize(decoder: Decoder): SourceThumbnail? =
        runCatching { parse(decoder.decodeSerializableValue(JsonElement.serializer())) }.getOrNull()

    private fun parse(element: JsonElement): SourceThumbnail? {
        if (element is JsonNull) return null
        val fields = element.jsonObject
        val bytes = fields.getValue("jpegData").jsonPrimitive.content.fromBase64()
        if (bytes.size > SourceThumbnail.MAXIMUM_BYTES) return null
        return SourceThumbnail(fields.getValue("width").jsonPrimitive.int, fields.getValue("height").jsonPrimitive.int, bytes)
    }
}
