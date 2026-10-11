package pl.dmq.peering.platform.store

import java.util.Base64
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

private const val PIN_KEY_SIZE = 65
private val serializer = MapSerializer(String.serializer(), String.serializer())

/** The pin file format: a JSON object from host id to the base64 of its 65-byte key. */
object PinCodec {
    fun encode(pins: Map<String, ByteArray>): ByteArray {
        val encoded = pins.mapValues { (_, key) -> Base64.getEncoder().encodeToString(key) }
        return Json.encodeToString(serializer, encoded).toByteArray(Charsets.UTF_8)
    }

    /** Anything that is not a well formed pin file reads as no pins. Entries with a wrong key size are dropped. */
    fun decode(bytes: ByteArray?): Map<String, ByteArray> {
        if (bytes == null) return emptyMap()
        val parsed = try {
            Json.decodeFromString(serializer, bytes.toString(Charsets.UTF_8))
        } catch (_: SerializationException) {
            return emptyMap()
        }
        return parsed.mapNotNull { (hostId, text) -> decodeKey(text)?.let { hostId to it } }.toMap()
    }

    private fun decodeKey(text: String): ByteArray? {
        val key = try {
            Base64.getDecoder().decode(text)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return key.takeIf { it.size == PIN_KEY_SIZE }
    }
}
