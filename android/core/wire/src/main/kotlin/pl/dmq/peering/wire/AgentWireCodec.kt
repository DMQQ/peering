package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject

/** One Swift case of a union: its case name, the class it decodes to, and the object holding its values. */
internal class UnionCase<T : Any>(
    val name: String,
    val type: Class<*>,
    val encode: (T) -> JsonObject,
    val decode: (JsonObject) -> T,
)

internal inline fun <T : Any, reified C : T> unionCase(name: String): UnionCase<T> = UnionCase(
    name = name,
    type = C::class.java,
    encode = { WireJson.encodeToJsonElement(it as C).jsonObject },
    decode = { WireJson.decodeFromJsonElement<C>(it) },
)

internal fun <T : Any> encodeUnion(codecs: List<UnionCase<T>>, value: T): JsonObject {
    val codec = codecs.first { it.type == value.javaClass }
    return swiftCase(codec.name, codec.encode(value))
}

internal fun <T : Any> decodeUnion(codecs: List<UnionCase<T>>, json: JsonObject): T {
    val (name, fields) = json.swiftCase()
    val codec = codecs.firstOrNull { it.name == name } ?: throw SwiftEnumException("unknown case $name")
    return codec.decode(fields)
}

/** Writes a union as its Swift case object, so it can sit inside another serialised model. */
internal abstract class SwiftCaseSerializer<T : Any> : KSerializer<T> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor

    abstract fun encodeCase(value: T): JsonObject

    abstract fun decodeCase(json: JsonObject): T

    override fun serialize(encoder: Encoder, value: T) {
        encoder.encodeSerializableValue(JsonObject.serializer(), encodeCase(value))
    }

    override fun deserialize(decoder: Decoder): T = decodeCase(decoder.decodeSerializableValue(JsonObject.serializer()))
}
