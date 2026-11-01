package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.sessionmode.TrackpadSwipe
import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.MouseDown
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.MouseUp
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.Scroll

class PictureGestureCanvasTest {
    private val sink = RecordingCommandSink()
    private val swipes = mutableListOf<TrackpadSwipe>()
    private val presenter = RemoteCanvasPresenter(sink, InputMode.DIRECT).apply {
        onCanvasSized(1000.0, 1000.0)
        onPictureChanged(PixelSize(1000.0, 1000.0))
        onSwiped = { swipes += it }
    }

    @Test
    fun `holding a direct touch right clicks there without pressing the left button`() {
        presenter.onPointerDown(1, 250.0, 750.0, timeMs = 0)

        assertTrue(presenter.onHoldElapsed(600))
        presenter.onPointerUp(1, 250.0, 750.0, timeMs = 700)

        assertEquals(listOf(MouseMove(pl.dmq.peering.wire.NormalizedPoint(0.25, 0.75)), MouseDown(MouseButton.RIGHT), MouseUp(MouseButton.RIGHT)), sink.sent)
    }

    @Test
    fun `holding in observe mode does nothing`() {
        presenter.setMode(InputMode.OBSERVE)
        presenter.onPointerDown(1, 250.0, 750.0, timeMs = 0)

        assertFalse(presenter.onHoldElapsed(600))
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `a two finger tap in direct mode right clicks and presses no left button`() {
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 10)
        presenter.onPointerUp(2, 600.0, 500.0, timeMs = 100)
        presenter.onPointerUp(1, 500.0, 500.0, timeMs = 110)

        assertFalse(sink.sent.contains(MouseDown(MouseButton.LEFT)))
        assertEquals(MouseUp(MouseButton.RIGHT), sink.sent.last())
    }

    @Test
    fun `a three finger swipe neither scrolls nor zooms nor clicks`() {
        listOf(1, 2, 3).forEach { presenter.onPointerDown(it, 300.0 + it * 60, 500.0, timeMs = 0) }
        listOf(1, 2, 3).forEach { presenter.onPointerMove(it, 300.0 + it * 90, 500.0, timeMs = 20) }
        listOf(1, 2, 3).forEach { presenter.onPointerMove(it, 500.0 + it * 90, 500.0, timeMs = 40) }
        listOf(1, 2, 3).forEach { presenter.onPointerUp(it, 500.0 + it * 90, 500.0, timeMs = 60) }

        assertEquals(listOf(TrackpadSwipe.RIGHT), swipes)
        assertTrue(sink.sent.none { it is Scroll || it is MouseDown })
        assertEquals(1.0, presenter.state.value.viewport.zoom, 1e-9)
    }

    @Test
    fun `a three finger swipe in trackpad mode reaches the swipe handler and clicks nothing`() {
        presenter.setMode(InputMode.TRACKPAD)
        listOf(1, 2, 3).forEach { presenter.onPointerDown(it, 300.0 + it * 60, 500.0, timeMs = 0) }
        listOf(1, 2, 3).forEach { presenter.onPointerMove(it, 300.0 + it * 60, 300.0, timeMs = 20) }
        listOf(1, 2, 3).forEach { presenter.onPointerUp(it, 300.0 + it * 60, 300.0, timeMs = 40) }

        assertEquals(listOf(TrackpadSwipe.UP), swipes)
        assertTrue(sink.sent.none { it is Scroll || it is MouseDown })
    }

    @Test
    fun `a swipe while observing is not sent`() {
        presenter.setMode(InputMode.OBSERVE)
        listOf(1, 2, 3).forEach { presenter.onPointerDown(it, 300.0 + it * 60, 500.0, timeMs = 0) }
        listOf(1, 2, 3).forEach { presenter.onPointerMove(it, 100.0 + it * 60, 500.0, timeMs = 20) }
        listOf(1, 2, 3).forEach { presenter.onPointerUp(it, 100.0 + it * 60, 500.0, timeMs = 40) }

        assertTrue(swipes.isEmpty())
    }
}
