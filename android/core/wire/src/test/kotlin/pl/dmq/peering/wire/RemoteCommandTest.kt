package pl.dmq.peering.wire

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteCommandTest {
    private val commandCases: List<Pair<String, String>> = VectorFiles.load("messages.json")
        .jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
        .filter { it.getValue("name").jsonPrimitive.content.startsWith("command ") }
        .map { it.getValue("name").jsonPrimitive.content to it.getValue("json").jsonPrimitive.content }

    @Test
    fun everyCommandVectorRoundTrips() {
        assertTrue("no command vectors found", commandCases.isNotEmpty())
        for ((name, json) in commandCases) {
            val encoded = RemoteCommand.parse(json).toJson()
            assertTrue("$name re-encodes to $encoded", jsonEquals(encoded, json))
        }
    }

    @Test
    fun vectorsDecodeToTheirTypedCases() {
        assertEquals(
            MouseMove(NormalizedPoint(0.5, 0.25)),
            RemoteCommand.parse("""{"mouseMove":{"to":{"x":0.5,"y":0.25}}}"""),
        )
        assertEquals(
            KeyDown(keyCode = 36, modifiers = Modifiers(Modifiers.COMMAND)),
            RemoteCommand.parse("""{"keyDown":{"keyCode":36,"modifiers":1048576}}"""),
        )
        assertEquals(
            SetCaptureSource(CaptureSource.Display(1)),
            RemoteCommand.parse("""{"setCaptureSource":{"_0":{"display":{"_0":1}}}}"""),
        )
        assertEquals(LockScreen, RemoteCommand.parse("""{"lockScreen":{}}"""))
    }

    @Test
    fun mouseButtonsAreTheirIntegerCodes() {
        assertEquals(MouseDown(MouseButton.RIGHT), RemoteCommand.parse("""{"mouseDown":{"button":1}}"""))
        assertEquals("""{"mouseUp":{"button":2}}""", MouseUp(MouseButton.MIDDLE).toJson())
    }

    @Test
    fun outOfRangeMouseButtonIsRefused() {
        assertThrows(SwiftEnumException::class.java) { RemoteCommand.parse("""{"mouseDown":{"button":3}}""") }
    }

    @Test
    fun unknownCaseIsRefusedNotCrashed() {
        assertThrows(SwiftEnumException::class.java) { RemoteCommand.parse("""{"somethingNew":{}}""") }
    }

    @Test
    fun unknownKeysInsideACaseAreIgnored() {
        assertEquals(LockScreen, RemoteCommand.parse("""{"lockScreen":{"futureField":1}}"""))
    }

    @Test
    fun commandWithoutOneObjectIsRefused() {
        assertThrows(SwiftEnumException::class.java) { RemoteCommand.parse("""{"lockScreen":{},"mouseDown":{}}""") }
        assertThrows(SwiftEnumException::class.java) { RemoteCommand.parse("""[1]""") }
    }

    @Test
    fun bareModifierBitsAreWrittenAsAnInteger() {
        val json = KeyUp(keyCode = 1, modifiers = Modifiers(Modifiers.SHIFT or Modifiers.CONTROL)).toJson()
        assertEquals("""{"keyUp":{"keyCode":1,"modifiers":${(1L shl 17) or (1L shl 18)}}}""", json)
    }
}
