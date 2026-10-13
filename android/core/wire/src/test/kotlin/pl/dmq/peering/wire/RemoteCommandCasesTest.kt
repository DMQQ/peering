package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteCommandCasesTest {
    private data class Case(
        val command: RemoteCommand,
        val json: String,
        val coalescing: Coalescing = Coalescing.NONE,
        val critical: Boolean = false,
        val userInput: Boolean = false,
    )

    private val cases = listOf(
        Case(MouseMove(NormalizedPoint(0.5, 0.5)), """{"mouseMove":{"to":{"x":0.5,"y":0.5}}}""", Coalescing.REPLACE_LATEST, userInput = true),
        Case(MouseDown(MouseButton.LEFT), """{"mouseDown":{"button":0}}""", critical = true, userInput = true),
        Case(MouseUp(MouseButton.LEFT), """{"mouseUp":{"button":0}}""", critical = true, userInput = true),
        Case(Scroll(0.0, -12.5), """{"scroll":{"dx":0,"dy":-12.5}}""", Coalescing.ACCUMULATE, userInput = true),
        Case(KeyDown(36, Modifiers(0)), """{"keyDown":{"keyCode":36,"modifiers":0}}""", critical = true, userInput = true),
        Case(KeyUp(36, Modifiers(0)), """{"keyUp":{"keyCode":36,"modifiers":0}}""", critical = true, userInput = true),
        Case(TextInput("hello"), """{"textInput":{"_0":"hello"}}""", userInput = true),
        Case(SwitchSpace(SpaceDirection.LEFT), """{"switchSpace":{"direction":"left"}}""", userInput = true),
        Case(SwitchToSpace(1, 2), """{"switchToSpace":{"display":1,"index":2}}""", userInput = true),
        Case(JoystickMove(0.0, 0.0), """{"joystickMove":{"dx":0,"dy":0}}""", Coalescing.ACCUMULATE, userInput = true),
        Case(SetCaptureSource(CaptureSource.Display(1)), """{"setCaptureSource":{"_0":{"display":{"_0":1}}}}""", critical = true),
        Case(LaunchApplication("x"), """{"launchApplication":{"bundleIdentifier":"x"}}""", critical = true),
        Case(SetStreamQuality(0, 8000), """{"setStreamQuality":{"fps":0,"bitrateKbps":8000}}"""),
        Case(SetVideoEnabled(false), """{"setVideoEnabled":{"_0":false}}""", critical = true),
        Case(RefreshSpacePreviews, """{"refreshSpacePreviews":{}}"""),
        Case(RefreshSourceThumbnails, """{"refreshSourceThumbnails":{}}"""),
        Case(WatchSourceThumbnails(true), """{"watchSourceThumbnails":{"_0":true}}"""),
        Case(SetPrivacyMode(true), """{"setPrivacyMode":{"enabled":true}}""", critical = true),
        Case(LockScreen, """{"lockScreen":{}}""", critical = true),
        Case(RequestClipboard, """{"requestClipboard":{}}"""),
        Case(PushClipboard("x"), """{"pushClipboard":{"text":"x"}}""", critical = true),
        Case(PushClipboardImage("AQI="), """{"pushClipboardImage":{"png":"AQI="}}""", critical = true),
        Case(ReportDeviceOrientation(true), """{"reportDeviceOrientation":{"isLandscape":true}}""", Coalescing.REPLACE_LATEST),
        Case(
            AddVirtualDisplay("", 1170, 2532, false),
            """{"addVirtualDisplay":{"name":"","width":1170,"height":2532,"startLandscape":false}}""",
        ),
        Case(RemoveVirtualDisplay(5), """{"removeVirtualDisplay":{"displayID":5}}"""),
        Case(RenameVirtualDisplay(5, "x"), """{"renameVirtualDisplay":{"displayID":5,"name":"x"}}"""),
        Case(PerformWindowAction(7, WindowAction.CLOSE), """{"performWindowAction":{"windowID":7,"action":"close"}}"""),
        Case(OpenNewWindow("x"), """{"openNewWindow":{"bundleIdentifier":"x"}}"""),
    )

    @Test
    fun everyCaseEncodesToItsDocumentedJson() {
        for (case in cases) {
            assertTrue("${case.json} vs ${case.command.toJson()}", jsonEquals(case.command.toJson(), case.json))
        }
    }

    @Test
    fun everyDocumentedJsonDecodesToItsCase() {
        for (case in cases) {
            assertEquals(case.command, RemoteCommand.parse(case.json))
        }
    }

    @Test
    fun coalescingFollowsTheDeliveryTable() {
        for (case in cases) {
            assertEquals(case.json.substringBefore(":"), case.coalescing, case.command.coalescing)
        }
    }

    @Test
    fun criticalCommandsAreTheOnesWhoseLossStrandsTheHost() {
        for (case in cases) {
            assertEquals(case.json.substringBefore(":"), case.critical, case.command.isCritical)
        }
    }

    @Test
    fun userInputIsPointerAndKeyboardOnly() {
        for (case in cases) {
            assertEquals(case.json.substringBefore(":"), case.userInput, case.command.isUserInput)
        }
    }

}
