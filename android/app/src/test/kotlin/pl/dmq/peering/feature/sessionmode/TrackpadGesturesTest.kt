package pl.dmq.peering.feature.sessionmode

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.RecordingCommandSink
import pl.dmq.peering.feature.remote.RemoteCanvasPresenter

class TrackpadGesturesTest {
    private val gestures = TrackpadGestures(
        RemoteCanvasPresenter(RecordingCommandSink(), InputMode.TRACKPAD).apply { onCanvasSized(1000.0, 1000.0) },
        swipeMinimumPx = 40.0,
        tapSlopPx = 10.0,
        onSwipe = { },
    )

    @Test
    fun aHostPointerIsAdoptedBeforeAnyFingerHasMoved() {
        assertTrue(gestures.adoptsHostPointer(nowMs = 0))
    }

    @Test
    fun aHostPointerIsIgnoredWhileAFingerIsDown() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)

        assertFalse(gestures.adoptsHostPointer(nowMs = 10_000))
    }

    @Test
    fun aHostPointerIsIgnoredForHalfASecondAfterTheLastMove() {
        gestures.down(1, 100.0, 100.0, timeMs = 0)
        gestures.move(1, 150.0, 100.0, timeMs = 100)
        gestures.up(1, 150.0, 100.0, timeMs = 120)

        assertFalse(gestures.adoptsHostPointer(nowMs = 599))
        assertTrue(gestures.adoptsHostPointer(nowMs = 600))
    }

    @Test
    fun aSwipeOnAHostWithoutDesktopsSendsNothing() {
        TrackpadSwipe.entries.forEach { assertTrue(it.commands(null, desktops = false).isEmpty()) }
    }
}
