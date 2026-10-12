package pl.dmq.peering.wire

import java.util.Base64
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive

/** Reads and writes the JSON that Swift's `JSONEncoder` produces for `Codable` types (protocol.md section 7). */
val WireJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = false
}

/** A SerializationException, so a decode that meets a case from a newer host fails like any other unreadable payload. */
class SwiftEnumException(message: String) : SerializationException(message)

/** A Swift enum case with associated values: `{"name":{"label":value}}`. A case without values passes no fields. */
fun swiftCase(name: String, fields: JsonObject = JsonObject(emptyMap())): JsonObject = JsonObject(mapOf(name to fields))

/** Splits `{"name":{...}}` into its case name and payload. Anything else is refused, never guessed at. */
fun JsonObject.swiftCase(): Pair<String, JsonObject> {
    val entry = entries.singleOrNull()
        ?: throw SwiftEnumException("expected exactly one case key, found ${size}")
    val payload = entry.value as? JsonObject
        ?: throw SwiftEnumException("case ${entry.key} does not carry an object payload")
    return entry.key to payload
}

fun ByteArray.toBase64(): String = Base64.getEncoder().encodeToString(this)

fun String.fromBase64(): ByteArray = Base64.getDecoder().decode(this)

fun JsonObjectBuilder.putIfPresent(key: String, value: String?) {
    if (value != null) put(key, JsonPrimitive(value))
}

fun JsonObjectBuilder.putIfPresent(key: String, value: Boolean?) {
    if (value != null) put(key, JsonPrimitive(value))
}

fun JsonObjectBuilder.putIfPresent(key: String, value: Long?) {
    if (value != null) put(key, JsonPrimitive(value))
}

fun JsonObjectBuilder.putIfPresent(key: String, value: Double?) {
    if (value != null) put(key, JsonPrimitive(value))
}

/**
 * Structural equality where numbers compare by value, so `1920` equals `1920.0`, which Swift and
 * other encoders write differently for the same pixel size.
 */
fun jsonEquals(a: String, b: String): Boolean =
    sameJson(WireJson.parseToJsonElement(a), WireJson.parseToJsonElement(b))

private fun sameJson(a: JsonElement, b: JsonElement): Boolean = when {
    a is JsonObject && b is JsonObject ->
        a.keys == b.keys && a.keys.all { key -> sameJson(a.getValue(key), b.getValue(key)) }
    a is JsonArray && b is JsonArray ->
        a.size == b.size && a.indices.all { index -> sameJson(a[index], b[index]) }
    a is JsonPrimitive && b is JsonPrimitive -> samePrimitive(a, b)
    else -> false
}

private fun samePrimitive(a: JsonPrimitive, b: JsonPrimitive): Boolean {
    if (a.isString || b.isString) return a.isString == b.isString && a.content == b.content
    val numberA = a.content.toBigDecimalOrNull()
    val numberB = b.content.toBigDecimalOrNull()
    if (numberA != null && numberB != null) return numberA.compareTo(numberB) == 0
    return a.content == b.content
}
