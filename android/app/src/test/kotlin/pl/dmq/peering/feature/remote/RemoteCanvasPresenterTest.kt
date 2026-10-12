package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.MouseDown
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.MouseUp
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.Scroll

class RemoteCanvasPresenterTest {
    private val sink = RecordingCommandSink()
    private val presenter = RemoteCanvasPresenter(sink, InputMode.TRACKPAD).apply {
        onCanvasSized(1000.0, 1000.0)
    }

    @Test
    fun `a single quick finger tap clicks the left button`() {
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)
        presenter.onPointerUp(1, 500.0, 500.0, timeMs = 100)

        assertEquals(listOf(MouseDown(MouseButton.LEFT), MouseUp(MouseButton.LEFT)), sink.sent)
    }

    @Test
    fun `a trackpad drag moves the cursor by the finger delta over the canvas width`() {
        presenter.onPointerDown(1, 100.0, 100.0, timeMs = 0)
        presenter.onPointerMove(1, 210.0, 100.0, timeMs = 10)

        assertMove(sink.sent.single(), x = 0.61, y = 0.5)
    }

    @Test
    fun `a direct touch lands at its place on the fitted picture`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPictureChanged(PixelSize(1920.0, 1080.0))

        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)

        assertMove(sink.sent[0], x = 0.5, y = 0.5)
        assertEquals(MouseDown(MouseButton.LEFT), sink.sent[1])
    }

    @Test
    fun `a direct touch in the letterbox clamps to the picture edge`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPictureChanged(PixelSize(1920.0, 1080.0))

        presenter.onPointerDown(1, 500.0, 0.0, timeMs = 0)

        assertMove(sink.sent[0], x = 0.5, y = 0.0)
    }

    @Test
    fun `a direct touch sends nothing while no picture is known`() {
        presenter.setMode(InputMode.DIRECT)

        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)
        presenter.onPointerUp(1, 500.0, 500.0, timeMs = 50)

        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `a second finger releases a held direct press so it is not a drag`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPictureChanged(PixelSize(1920.0, 1080.0))
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)

        presenter.onPointerDown(2, 300.0, 500.0, timeMs = 10)

        assertEquals(MouseUp(MouseButton.LEFT), sink.sent.last())
    }

    @Test
    fun `leaving direct mode releases a held press`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPictureChanged(PixelSize(1920.0, 1080.0))
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)

        presenter.setMode(InputMode.TRACKPAD)

        assertEquals(MouseUp(MouseButton.LEFT), sink.sent.last())
    }

    @Test
    fun `spreading two fingers zooms the view about their midpoint without scrolling the Mac`() {
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)

        presenter.onPointerMove(2, 700.0, 500.0, timeMs = 10)

        val viewport = presenter.state.value.viewport
        assertEquals(1.5, viewport.zoom, EPSILON)
        assertEquals(-225.0, viewport.panX, EPSILON)
        assertEquals(-250.0, viewport.panY, EPSILON)
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `two fingers moving together scroll the Mac in trackpad mode`() {
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)

        presenter.onPointerMove(1, 400.0, 520.0, timeMs = 10)

        assertEquals(listOf<RemoteCommand>(Scroll(0.0, 20.0)), sink.sent)
        assertEquals(1.0, presenter.state.value.viewport.zoom, EPSILON)
    }

    @Test
    fun `a two finger tap right clicks in trackpad mode`() {
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 10)
        presenter.onPointerUp(2, 600.0, 500.0, timeMs = 90)
        presenter.onPointerUp(1, 400.0, 500.0, timeMs = 100)

        assertEquals(listOf(MouseDown(MouseButton.RIGHT), MouseUp(MouseButton.RIGHT)), sink.sent)
    }

    @Test
    fun `a long press then a move drags with the left button held in trackpad mode`() {
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)
        presenter.onPointerMove(1, 520.0, 500.0, timeMs = 500)
        presenter.onPointerUp(1, 520.0, 500.0, timeMs = 600)

        assertEquals(MouseDown(MouseButton.LEFT), sink.sent.first())
        assertEquals(MouseUp(MouseButton.LEFT), sink.sent.last())
        assertTrue(sink.sent.any { it is MouseMove })
    }

    @Test
    fun `a tap clicks nothing in direct mode beyond its own press and release`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPictureChanged(PixelSize(1000.0, 1000.0))
        presenter.onPointerDown(1, 500.0, 500.0, timeMs = 0)
        presenter.onPointerUp(1, 500.0, 500.0, timeMs = 80)

        assertEquals(1, sink.sent.count { it == MouseDown(MouseButton.LEFT) })
        assertEquals(1, sink.sent.count { it == MouseUp(MouseButton.LEFT) })
    }

    @Test
    fun `switching to touch mid pinch keeps the zoom`() {
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)
        presenter.onPointerMove(2, 700.0, 500.0, timeMs = 10)
        val zoom = presenter.state.value.viewport.zoom
        presenter.setMode(InputMode.DIRECT)

        assertEquals(zoom, presenter.state.value.viewport.zoom, EPSILON)
        assertTrue(zoom > 1.0)
    }

    @Test
    fun `two fingers moving together scroll the Mac in direct mode by their midpoint`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)

        presenter.onPointerMove(1, 400.0, 520.0, timeMs = 10)

        assertEquals(listOf<RemoteCommand>(Scroll(0.0, 10.0)), sink.sent)
    }

    @Test
    fun `spreading fingers in direct mode zooms and sends no scroll`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)

        presenter.onPointerMove(2, 700.0, 500.0, timeMs = 10)

        assertEquals(1.5, presenter.state.value.viewport.zoom, EPSILON)
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `fit returns a zoomed view to unzoomed`() {
        presenter.onPointerDown(1, 400.0, 500.0, timeMs = 0)
        presenter.onPointerDown(2, 600.0, 500.0, timeMs = 0)
        presenter.onPointerMove(2, 700.0, 500.0, timeMs = 10)

        presenter.fitToCanvas()

        assertEquals(CanvasViewport(), presenter.state.value.viewport)
    }

    @Test
    fun `the published picture rectangle follows the fitted picture`() {
        presenter.onPictureChanged(PixelSize(1920.0, 1080.0))

        val picture = presenter.state.value.picture!!
        assertEquals(562.5, picture.height, EPSILON)
        assertEquals(218.75, picture.top, EPSILON)
    }

    private fun assertMove(command: RemoteCommand, x: Double, y: Double) {
        val move = command as MouseMove
        assertEquals(x, move.to.x, EPSILON)
        assertEquals(y, move.to.y, EPSILON)
    }

    private companion object {
        const val EPSILON = 1e-6
    }
}
