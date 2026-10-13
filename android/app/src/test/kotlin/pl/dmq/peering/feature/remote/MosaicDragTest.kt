package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.MosaicTile
import pl.dmq.peering.wire.NormalizedRect
import pl.dmq.peering.wire.PixelSize

class MosaicDragTest {
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
    private val moves = mutableListOf<Pair<Int, Int>>()
    private val opened = mutableListOf<CaptureSource>()
    private val presenter = RemoteCanvasPresenter(sink, InputMode.TRACKPAD).apply {
        onCanvasSized(1000.0, 1000.0)
        onPictureChanged(layout.canvas)
        setMosaic(layout)
        onTileMoved = { from, to -> moves += from to to }
        onTileTapped = { opened += it }
    }

    private fun holdOn(x: Double, y: Double) {
        presenter.onPointerDown(1, x, y, 0)
        presenter.onHoldElapsed()
    }

    @Test
    fun `a press that stays put is waiting to lift until the hold time has passed`() {
        presenter.onPointerDown(1, 200.0, 500.0, 1000)

        assertEquals(MosaicLift.HOLD_MS, presenter.holdRemaining(1000))
        assertEquals(0L, presenter.holdRemaining(1000 + MosaicLift.HOLD_MS + 50))
    }

    @Test
    fun `holding lifts the tile under the finger`() {
        holdOn(200.0, 500.0)

        val drag = presenter.state.value.drag
        assertEquals(0, drag?.held)
        assertEquals(0, drag?.target)
    }

    @Test
    fun `dragging across to the other tile and letting go moves the tile there`() {
        holdOn(200.0, 500.0)
        presenter.onPointerMove(1, 600.0, 500.0, 600)
        presenter.onPointerMove(1, 800.0, 500.0, 700)
        presenter.onPointerUp(1, 800.0, 500.0, 800)

        assertEquals(listOf(0 to 1), moves)
        assertNull(presenter.state.value.drag)
        assertTrue(opened.isEmpty())
    }

    @Test
    fun `crossing a seam keeps the last target`() {
        holdOn(200.0, 500.0)
        presenter.onPointerMove(1, 800.0, 500.0, 600)
        presenter.onPointerMove(1, 500.0, 100.0, 700)

        assertEquals(1, presenter.state.value.drag?.target)
    }

    @Test
    fun `letting go over the tile it came from moves nothing`() {
        holdOn(200.0, 500.0)
        presenter.onPointerMove(1, 300.0, 500.0, 600)
        presenter.onPointerUp(1, 300.0, 500.0, 700)

        assertTrue(moves.isEmpty())
    }

    @Test
    fun `a lifted tile does not pan the picture`() {
        val before = presenter.state.value.viewport
        holdOn(200.0, 500.0)
        presenter.onPointerMove(1, 800.0, 500.0, 600)

        assertEquals(before, presenter.state.value.viewport)
    }

    @Test
    fun `a press that moves before the hold time never lifts`() {
        presenter.onPointerDown(1, 200.0, 500.0, 0)
        presenter.onPointerMove(1, 260.0, 500.0, 100)

        assertNull(presenter.holdRemaining(100))
        assertFalse(presenter.onHoldElapsed())
    }

    @Test
    fun `a second finger puts a lifted tile back`() {
        holdOn(200.0, 500.0)
        presenter.onPointerDown(2, 700.0, 500.0, 600)

        assertNull(presenter.state.value.drag)
        presenter.onPointerUp(2, 700.0, 500.0, 700)
        presenter.onPointerUp(1, 200.0, 500.0, 700)
        assertTrue(moves.isEmpty())
    }

    @Test
    fun `a hold in the bars beside the picture lifts nothing`() {
        presenter.onPointerDown(1, 500.0, 100.0, 0)

        assertFalse(presenter.onHoldElapsed())
        assertNull(presenter.state.value.drag)
    }

    @Test
    fun `overlay tiles carry names, a close button, and follow a lifted tile`() {
        val fit = CanvasRect(0.0, 250.0, 1000.0, 500.0)
        val viewport = CanvasViewport()
        val still = overlayTiles(layout, viewport, fit, null, 1.0) { if (it == left) "Notes" else null }

        assertEquals("Notes", still[0].title)
        assertTrue(still.all { it.showsTitle && it.showsClose })
        assertEquals(CanvasRect(0.0, 250.0, 500.0, 500.0), still[0].rect)

        val lifted = overlayTiles(layout, viewport, fit, MosaicDrag(0, 1, 700.0, 300.0), 1.0) { null }
        assertEquals(450.0, lifted[0].rect.left, 0.001)
        assertTrue(lifted[0].held)
        assertTrue(lifted[1].target)
        assertTrue(lifted.none { it.showsClose })
    }

    @Test
    fun `a small tile gets neither a name nor a close button`() {
        val fit = CanvasRect(0.0, 250.0, 200.0, 100.0)

        val tiles = overlayTiles(layout, CanvasViewport(), fit, null, 1.0) { "Notes" }

        assertTrue(tiles.none { it.showsTitle || it.showsClose })
    }
}
