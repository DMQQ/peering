package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource

class MosaicPanelTest {
    private val sink = RecordingCommandSink()
    private val presenter = SourcesPresenter(sink)
    private val phone = PixelSize(1080.0, 2400.0)
    private val windows = List(3) { CaptureSource.Window(it + 1L) }

    @Test
    fun `one pick is not a mosaic and two are`() {
        assertFalse(MosaicPicks().toggled(windows[0]).canStart)
        assertTrue(MosaicPicks().toggled(windows[0]).toggled(windows[1]).canStart)
    }

    @Test
    fun `picks keep their order and a second tap drops one`() {
        val picks = MosaicPicks().toggled(windows[2]).toggled(windows[0])

        assertEquals(1, picks.place(windows[2]))
        assertEquals(2, picks.place(windows[0]))
        assertNull(picks.toggled(windows[2]).place(windows[2]))
    }

    @Test
    fun `a tenth pick is refused`() {
        var picks = MosaicPicks()
        repeat(10) { picks = picks.toggled(CaptureSource.Window(it.toLong())) }

        assertEquals(MosaicLayout.MAXIMUM_TILES, picks.sources.size)
        assertTrue(picks.canStart)
    }

    @Test
    fun `starting sends the mosaic through the ordinary source command`() {
        val picks = MosaicPicks(windows)

        assertTrue(presenter.showMosaic(picks, phone, catalog = null))

        val sent = sink.sent.single() as SetCaptureSource
        val layout = (sent.source as CaptureSource.Mosaic).layout!!
        assertEquals(windows, layout.tiles.map { it.source })
    }

    @Test
    fun `starting with too few sends nothing`() {
        assertFalse(presenter.showMosaic(MosaicPicks(windows.take(1)), phone, catalog = null))

        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `the way back asks for the same layout`() {
        presenter.showMosaic(MosaicPicks(windows), phone, catalog = null)
        val layout = ((sink.sent.single() as SetCaptureSource).source as CaptureSource.Mosaic).layout!!
        sink.sent.clear()

        presenter.returnToMosaic(layout)

        assertEquals(SetCaptureSource(CaptureSource.Mosaic(layout)), sink.sent.single())
    }

    @Test
    fun `the pill names a mosaic by its window count and otherwise the source`() {
        assertEquals("3 windows", sourceLine("orders.ts", "3 windows"))
        assertEquals("orders.ts", sourceLine("orders.ts", null))
        assertNull(sourceLine(null, null))
    }

    @Test
    fun `a mosaic hides the joystick the wheel and the cursor`() {
        assertTrue(ChromePolicy.pointerControlsShown(keyboardShown = false, mosaic = false))
        assertFalse(ChromePolicy.pointerControlsShown(keyboardShown = false, mosaic = true))
        assertTrue(ChromePolicy.cursorShown(InputMode.DIRECT, PictureState.LIVE, mosaic = false))
        assertFalse(ChromePolicy.cursorShown(InputMode.DIRECT, PictureState.LIVE, mosaic = true))
    }
}
