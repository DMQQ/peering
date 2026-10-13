package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.RequestClipboard

class WheelAndJoystickTest {
    @Test
    fun travelBecomesWholeNotchesAndTheRemainderCarries() {
        val wheel = ScrollWheelState()

        assertEquals(0, wheel.roll(11.0))
        assertEquals(1, wheel.roll(2.0))
        assertEquals(-2, wheel.roll(-25.0))
    }

    @Test
    fun aFastFlickDeliversEveryNotchItCrossed() {
        assertEquals(3, ScrollWheelState().roll(37.0))
    }

    @Test
    fun seatingMovesAtMostHalfANotchToTheNearestDetent() {
        val wheel = ScrollWheelState()
        wheel.roll(7.0)

        assertEquals(1, wheel.seat())
        assertEquals(0, wheel.seat())
        assertEquals(1, wheel.delivered)
    }

    @Test
    fun aFlickIsCappedAndASlowDragDoesNotCoast() {
        assertEquals(WheelSpin.LAUNCH_LIMIT, WheelSpin.launch(pointsPerSecond = 1_000_000.0), 0.0)
        assertEquals(0.0, WheelSpin.duration(WheelSpin.STALLING), 0.0)
        assertTrue(WheelSpin.duration(60.0) > 0)
    }

    @Test
    fun theSpeedCycleStepsThroughTheListAndBackToTheStart() {
        assertEquals(1.5, JoystickMath.nextSpeed(1.0), 0.0)
        assertEquals(1.0, JoystickMath.nextSpeed(3.0), 0.0)
        assertEquals(1.5, JoystickMath.nextSpeed(7.0), 0.0)
        assertEquals("2", JoystickMath.speedLabel(2.0))
        assertEquals("2.5", JoystickMath.speedLabel(2.5))
    }

    @Test
    fun fullDeflectionCoversOnePointWidthAndAHalfPerSecond() {
        val (dx, dy) = JoystickMath.travel(x = 50.0, y = 0.0, radius = 50.0, pointWidth = 1000.0, pointHeight = 600.0, seconds = 0.02)

        assertEquals(30.0, dx, 1e-9)
        assertEquals(0.0, dy, 1e-9)
    }

    @Test
    fun aLongGapIsCappedSoTheFirstSampleDoesNotJump() {
        val (dx, _) = JoystickMath.travel(x = 50.0, y = 0.0, radius = 50.0, pointWidth = 1000.0, pointHeight = 600.0, seconds = 2.0)

        assertEquals(75.0, dx, 1e-9)
    }

    @Test
    fun aKnobDraggedPastTheRingStaysOnIt() {
        val (x, y) = JoystickMath.clamped(100.0, 0.0, radius = 50.0)

        assertEquals(50.0, x, 1e-9)
        assertEquals(0.0, y, 1e-9)
    }

    @Test
    fun observingBlocksWhatTheUserDoesAndNothingElse() {
        val sink = RecordingCommandSink()
        var observing = true
        val gate = ObserveGate(sink) { observing }

        gate.send(KeyDown(8, Modifiers(Modifiers.COMMAND)))
        gate.send(RequestClipboard)
        observing = false
        gate.send(KeyDown(8, Modifiers(Modifiers.COMMAND)))

        assertEquals(listOf(RequestClipboard, KeyDown(8, Modifiers(Modifiers.COMMAND))), sink.sent)
    }
}
