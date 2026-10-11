package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SwiftEnumJsonTest {
    @Test
    fun valueCaseWritesUnlabelledPayloadAsUnderscoreZero() {
        val case = swiftCase("setVideoEnabled", buildJsonObject { put("_0", JsonPrimitive(false)) })
        assertEquals("""{"setVideoEnabled":{"_0":false}}""", WireJson.encodeToString(JsonObject.serializer(), case))
    }

    @Test
    fun caseWithoutValuesWritesEmptyObject() {
        val case = swiftCase("lockScreen")
        assertEquals("""{"lockScreen":{}}""", WireJson.encodeToString(JsonObject.serializer(), case))
    }

    @Test
    fun swiftCaseReadsNameAndPayload() {
        val (name, payload) = WireJson.parseToJsonElement("""{"mouseDown":{"button":2}}""").jsonObject.swiftCase()
        assertEquals("mouseDown", name)
        assertEquals(JsonPrimitive(2), payload.getValue("button"))
    }

    @Test
    fun swiftCaseReadsEmptyPayload() {
        val (name, payload) = WireJson.parseToJsonElement("""{"lockScreen":{}}""").jsonObject.swiftCase()
        assertEquals("lockScreen", name)
        assertTrue(payload.isEmpty())
    }

    @Test
    fun objectWithTwoKeysIsRefused() {
        val json = WireJson.parseToJsonElement("""{"a":{},"b":{}}""").jsonObject
        assertThrows(SwiftEnumException::class.java) { json.swiftCase() }
    }

    @Test
    fun objectWithNoKeysIsRefused() {
        assertThrows(SwiftEnumException::class.java) { JsonObject(emptyMap()).swiftCase() }
    }

    @Test
    fun caseWithScalarPayloadIsRefused() {
        val json = WireJson.parseToJsonElement("""{"lockScreen":true}""").jsonObject
        assertThrows(SwiftEnumException::class.java) { json.swiftCase() }
    }

    @Test
    fun bytesEncodeAsPaddedStandardBase64() {
        assertEquals("AQI=", byteArrayOf(1, 2).toBase64())
        assertEquals("AQEB", byteArrayOf(1, 1, 1).toBase64())
    }

    @Test
    fun base64TextDecodesToTheSameBytes() {
        assertTrue("AQI=".fromBase64().contentEquals(byteArrayOf(1, 2)))
        assertTrue("AQEB".fromBase64().contentEquals(byteArrayOf(1, 1, 1)))
    }

    @Test
    fun base64RoundTripsEveryByteValue() {
        val bytes = ByteArray(256) { it.toByte() }
        assertTrue(bytes.toBase64().fromBase64().contentEquals(bytes))
    }

    @Test
    fun nullValuesAreAbsentAndPresentValuesAreWritten() {
        val json = buildJsonObject {
            putIfPresent("text", "hi")
            putIfPresent("flag", true)
            putIfPresent("count", 7L)
            putIfPresent("ratio", 0.5)
            putIfPresent("missingText", null as String?)
            putIfPresent("missingFlag", null as Boolean?)
            putIfPresent("missingCount", null as Long?)
            putIfPresent("missingRatio", null as Double?)
        }
        assertEquals(
            """{"text":"hi","flag":true,"count":7,"ratio":0.5}""",
            WireJson.encodeToString(JsonObject.serializer(), json),
        )
    }

    @Test
    fun numbersCompareByValue() {
        assertTrue(jsonEquals("""{"w":1920}""", """{"w":1920.0}"""))
        assertFalse(jsonEquals("""{"w":1920}""", """{"w":1921}"""))
    }

    @Test
    fun keyOrderAndWhitespaceAreIgnored() {
        assertTrue(jsonEquals("""{"a":1,"b":[true,null]}""", """{ "b" : [ true , null ], "a" : 1 }"""))
    }

    @Test
    fun stringsAreNotNumbers() {
        assertFalse(jsonEquals("""{"a":"1920"}""", """{"a":1920}"""))
        assertFalse(jsonEquals("""{"a":"true"}""", """{"a":true}"""))
    }

    @Test
    fun differentKeysOrLengthsAreNotEqual() {
        assertFalse(jsonEquals("""{"a":1}""", """{"a":1,"b":2}"""))
        assertFalse(jsonEquals("""[1,2]""", """[1]"""))
    }
}
