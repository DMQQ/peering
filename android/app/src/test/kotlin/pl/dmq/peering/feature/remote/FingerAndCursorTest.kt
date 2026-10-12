package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize

/** The finger, the Mac's pointer and the drawn glyph, wired as the remote screen wires them. */
class FingerAndCursorTest {
    private val sink = RecordingCommandSink()
    private val tracker = PointerTracker(sink) { 1920.0 to 1080.0 }
    private val presenter = RemoteCanvasPresenter(tracker, InputMode.TRACKPAD) { tracker.position.value }.apply {
        onCanvasSized(1000.0, 1000.0)
        onPictureChanged(PixelSize(1920.0, 1080.0))
    }

    private fun lastMove(): NormalizedPoint = (sink.sent.last { it is MouseMove } as MouseMove).to

    private fun assertAt(expected: NormalizedPoint, actual: NormalizedPoint) {
        assertEquals(expected.x, actual.x, 1e-9)
        assertEquals(expected.y, actual.y, 1e-9)
    }

    @Test
    fun `a control drag moves the cursor by the same share of the picture on both axes`() {
        presenter.onPointerDown(1, 300.0, 300.0, 0)
        presenter.onPointerMove(1, 400.0, 356.25, 10)

        assertAt(NormalizedPoint(0.6, 0.6), lastMove())
    }

    @Test
    fun `the glyph is where the last command put the cursor after a control drag`() {
        presenter.onPointerDown(1, 300.0, 300.0, 0)
        presenter.onPointerMove(1, 400.0, 356.25, 10)
        presenter.onPointerUp(1, 400.0, 356.25, 20)

        assertAt(lastMove(), tracker.position.value)
    }

    @Test
    fun `a control drag after the joystick starts from where the joystick left the cursor`() {
        tracker.send(JoystickMove(192.0, 108.0))
        presenter.onPointerDown(1, 300.0, 300.0, 0)
        presenter.onPointerMove(1, 400.0, 300.0, 10)

        assertAt(NormalizedPoint(0.7, 0.6), lastMove())
    }

    @Test
    fun `a control drag after the Mac moved its own pointer starts from the host report`() {
        tracker.report(NormalizedPoint(0.2, 0.8))
        presenter.onPointerDown(1, 300.0, 300.0, 0)
        presenter.onPointerMove(1, 301.0, 300.0, 10)

        assertEquals(0.201, lastMove().x, 1e-9)
        assertEquals(0.8, lastMove().y, 1e-9)
    }

    @Test
    fun `the first move after a control touch down does not jump the cursor`() {
        presenter.onPointerDown(1, 900.0, 900.0, 0)
        presenter.onPointerMove(1, 900.0, 900.0, 5)
        presenter.onPointerMove(1, 901.0, 900.0, 10)

        assertEquals(0.501, lastMove().x, 1e-9)
        assertEquals(0.5, lastMove().y, 1e-9)
    }

    @Test
    fun `the host report moves the glyph and a later report replaces an earlier one`() {
        tracker.report(NormalizedPoint(0.1, 0.9))
        tracker.report(NormalizedPoint(0.3, 0.4))

        assertAt(NormalizedPoint(0.3, 0.4), tracker.position.value)
    }

    @Test
    fun `a touch drag puts the cursor under the finger through the letterbox`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPointerDown(1, 250.0, 500.0, 0)
        presenter.onPointerMove(1, 750.0, 218.75 + 562.5 * 0.25, 10)

        assertAt(NormalizedPoint(0.75, 0.25), lastMove())
        assertAt(lastMove(), tracker.position.value)
    }

    @Test
    fun `a touch drag follows zoom and pan`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.fillCanvas()
        val shown = presenter.state.value.picture!!
        presenter.onPointerDown(1, 500.0, 500.0, 0)
        presenter.onPointerMove(1, 1000.0, 500.0, 10)

        assertAt(NormalizedPoint((1000.0 - shown.left) / shown.width, 0.5), lastMove())
    }

    @Test
    fun `a touch drag outside the picture stops at its edge`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPointerDown(1, 500.0, 500.0, 0)
        presenter.onPointerMove(1, 500.0, 5.0, 10)

        assertAt(NormalizedPoint(0.5, 0.0), lastMove())
    }

    @Test
    fun `a touch down sends the position before the press so the click lands under the finger`() {
        presenter.setMode(InputMode.DIRECT)
        presenter.onPointerDown(1, 500.0, 500.0, 0)

        assertEquals(MouseMove::class, sink.sent.first()::class)
    }
}
