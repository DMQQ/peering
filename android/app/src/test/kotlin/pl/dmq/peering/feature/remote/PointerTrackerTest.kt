package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.NormalizedPoint

class PointerTrackerTest {
    private val sink = RecordingCommandSink()
    private val tracker = PointerTracker(sink) { 1000.0 to 500.0 }

    @Test
    fun startsInTheMiddle() {
        assertEquals(NormalizedPoint(0.5, 0.5), tracker.position.value)
    }

    @Test
    fun aMoveReplacesThePosition() {
        tracker.send(MouseMove(NormalizedPoint(0.2, 0.9)))
        assertEquals(NormalizedPoint(0.2, 0.9), tracker.position.value)
    }

    @Test
    fun theJoystickAdvancesItByTheTravelOverThePictureSize() {
        tracker.send(JoystickMove(100.0, -50.0))
        assertEquals(0.6, tracker.position.value.x, 1e-9)
        assertEquals(0.4, tracker.position.value.y, 1e-9)
    }

    @Test
    fun theJoystickStopsAtTheEdges() {
        tracker.send(JoystickMove(5000.0, -5000.0))
        assertEquals(NormalizedPoint(1.0, 0.0), tracker.position.value)
    }

    @Test
    fun everyCommandStillReachesTheComputer() {
        tracker.send(MouseMove(NormalizedPoint(0.1, 0.1)))
        tracker.send(JoystickMove(1.0, 1.0))
        assertEquals(2, sink.sent.size)
    }
}
