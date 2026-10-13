package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.video.MosaicEdit
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SetCaptureSource

class MosaicEditTest {
    private val sink = RecordingCommandSink()
    private val presenter = SourcesPresenter(sink)
    private val phone = PixelSize(2400.0, 1080.0)
    private val windows = List(3) { CaptureSource.Window(it + 1L) }

    private fun shown(): MosaicLayout {
        presenter.showMosaic(MosaicPicks(windows), phone, catalog = null)
        val layout = ((sink.sent.single() as SetCaptureSource).source as CaptureSource.Mosaic).layout!!
        sink.sent.clear()
        return layout
    }

    private fun lastLayout(): MosaicLayout =
        ((sink.sent.last() as SetCaptureSource).source as CaptureSource.Mosaic).layout!!

    @Test
    fun `reordering asks for the same windows in the new order`() {
        val layout = shown()

        assertTrue(presenter.edit(layout, MosaicEdit.Move(0, 2), phone, null))

        assertEquals(listOf(windows[1], windows[2], windows[0]), lastLayout().tiles.map { it.source })
    }

    @Test
    fun `removing a tile asks for a mosaic of the rest`() {
        val layout = shown()

        assertTrue(presenter.edit(layout, MosaicEdit.Remove(1), phone, null))

        assertEquals(listOf(windows[0], windows[2]), lastLayout().tiles.map { it.source })
    }

    @Test
    fun `removing down to one tile shows that window on its own`() {
        val two = shown().let { presenter.edit(it, MosaicEdit.Remove(2), phone, null); lastLayout() }

        presenter.edit(two, MosaicEdit.Remove(0), phone, null)

        assertEquals(SetCaptureSource(windows[1]), sink.sent.last())
    }

    @Test
    fun `a bigger tile takes more of its row and keeps the size through another edit`() {
        val layout = shown()
        presenter.edit(layout, MosaicEdit.Resize(0, 1), phone, null)
        val bigger = lastLayout()
        assertTrue(bigger.tiles[0].rect.width > bigger.tiles[1].rect.width)

        presenter.edit(bigger, MosaicEdit.Move(0, 1), phone, null)

        val moved = lastLayout()
        assertEquals(windows[0], moved.tiles[1].source)
        assertTrue(moved.tiles[1].rect.width > moved.tiles[0].rect.width)
    }

    @Test
    fun `an edit that changes nothing sends nothing`() {
        val layout = shown()

        assertFalse(presenter.edit(layout, MosaicEdit.Resize(0, -1), phone, null))
        assertFalse(presenter.edit(layout, MosaicEdit.Move(1, 1), phone, null))

        assertTrue(sink.sent.isEmpty())
    }
}
