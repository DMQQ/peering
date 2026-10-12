package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray

/** A list read element by element, dropping an element whose Swift case this build does not know instead of the whole list. */
internal abstract class UnknownCaseSkippingList<T>(private val element: KSerializer<T>) : KSerializer<List<T>> {
    private val whole = ListSerializer(element)

    override val descriptor: SerialDescriptor = whole.descriptor

    override fun serialize(encoder: Encoder, value: List<T>) = whole.serialize(encoder, value)

    override fun deserialize(decoder: Decoder): List<T> =
        decoder.decodeSerializableValue(JsonArray.serializer()).mapNotNull { item ->
            try {
                WireJson.decodeFromJsonElement(element, item)
            } catch (unknown: SwiftEnumException) {
                null
            }
        }
}

internal object AgentStreamEventsSerializer : UnknownCaseSkippingList<AgentStreamEvent>(AgentStreamEvent.serializer())
