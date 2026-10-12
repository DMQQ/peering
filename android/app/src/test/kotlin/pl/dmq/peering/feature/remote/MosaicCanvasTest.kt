package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.MosaicTile
import pl.dmq.peering.wire.NormalizedRect
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SpaceDirection
import pl.dmq.peering.wire.SwitchSpace

class MosaicCanvasTest {
    private val left = CaptureSource.Window(1)
    private val right = CaptureSource.Window(2)
    private val layout = MosaicLayout(
        PixelSize(2000.0, 1000.0),
        listOf(
            MosaicTile(left, NormalizedRect(0.0, 0.0, 0.5, 1.0)),
            MosaicTile(right, NormalizedRect(0.5, 0.0, 0.5, 1.0)),
        ),
        15,
    )
    private val sink = RecordingCommandSink()
    private val opened = mutableListOf<CaptureSource>()
    private val presenter = RemoteCanvasPresenter(sink, InputMode.TRACKPAD).apply {
        onCanvasSized(1000.0, 1000.0)
        onPictureChanged(layout.canvas)
        setMosaic(layout)
        onTileTapped = { opened += it }
    }

    private fun tap(x: Double, y: Double, from: Long = 0) {
        presenter.onPointerDown(1, x, y, from)
        presenter.onPointerUp(1, x, y, from + 80)
    }

    @Test
    fun `a tap on the left tile opens the left source`() {
        tap(200.0, 500.0)

        assertEquals(listOf<CaptureSource>(left), opened)
    }

    @Test
    fun `a tap on the right tile opens the right source`() {
        tap(800.0, 500.0)

        assertEquals(listOf<CaptureSource>(right), opened)
    }

    @Test
    fun `a tap in the bars above and below the picture opens nothing`() {
        tap(500.0, 100.0)
        tap(500.0, 900.0)

        assertTrue(opened.isEmpty())
    }

    @Test
    fun `a tap sends no mouse command while a mosaic is up`() {
        tap(200.0, 500.0)

        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `a drag pans and opens nothing`() {
        presenter.onPointerDown(1, 200.0, 500.0, 0)
        presenter.onPointerMove(1, 260.0, 520.0, 30)
        presenter.onPointerUp(1, 260.0, 520.0, 60)

        assertTrue(opened.isEmpty())
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `a long press opens nothing`() {
        presenter.onPointerDown(1, 200.0, 500.0, 1000)
        presenter.onPointerUp(1, 200.0, 500.0, 2000)

        assertTrue(opened.isEmpty())
    }

    @Test
    fun `two fingers never count as a tap`() {
        presenter.onPointerDown(1, 200.0, 500.0, 0)
        presenter.onPointerDown(2, 800.0, 500.0, 5)
        presenter.onPointerUp(2, 800.0, 500.0, 50)
        presenter.onPointerUp(1, 200.0, 500.0, 60)

        assertTrue(opened.isEmpty())
    }

    @Test
    fun `leaving the mosaic gives the tap back to the mouse`() {
        presenter.setMosaic(null)

        tap(500.0, 500.0)

        assertTrue(opened.isEmpty())
        assertTrue(sink.sent.isNotEmpty())
    }

    @Test
    fun `the gate drops keys and points while a mosaic is up but lets Space switching and the source change through`() {
        var showing = true
        val gate = MosaicGate(sink) { showing }

        gate.send(KeyDown(36, Modifiers(0)))
        gate.send(SwitchSpace(SpaceDirection.LEFT))
        gate.send(pl.dmq.peering.wire.SetCaptureSource(left))
        showing = false
        gate.send(KeyDown(36, Modifiers(0)))

        assertEquals(
            listOf(SwitchSpace(SpaceDirection.LEFT), pl.dmq.peering.wire.SetCaptureSource(left), KeyDown(36, Modifiers(0))),
            sink.sent,
        )
    }

    @Test
    fun `a point on the letterbox is no tile and zoom moves the tiles under the finger`() {
        val fit = CanvasRect(0.0, 250.0, 1000.0, 500.0)
        val unzoomed = CanvasViewport()

        assertNull(MosaicHit.tileAt(layout, unzoomed, fit, 500.0, 100.0))
        assertEquals(0, MosaicHit.tileAt(layout, unzoomed, fit, 400.0, 500.0))

        val zoomed = unzoomed.zoomedAbout(2.0, 0.0, 0.0, CanvasSize(1000.0, 1000.0))
        assertEquals(0, MosaicHit.tileAt(layout, zoomed, fit, 900.0, 800.0))
        assertEquals(1, MosaicHit.tileAt(layout, zoomed, fit, 1100.0, 800.0))
    }
}
