package pl.dmq.peering.session.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PixelSize

class MosaicGridTest {
    private val phone = PixelSize(1080.0, 2400.0)
    private val sources = listOf(CaptureSource.Window(1), CaptureSource.Window(2), CaptureSource.Window(3), CaptureSource.Window(4))

    @Test
    fun fourTilesFormTwoByTwoInEitherOrientation() {
        assertEquals(2, MosaicGrid.columns(4, portrait = true))
        assertEquals(2, MosaicGrid.columns(4, portrait = false))
    }

    @Test
    fun aPortraitScreenGivesThreeTilesFewerColumnsThanLandscape() {
        assertEquals(1, MosaicGrid.columns(3, portrait = true))
        assertEquals(2, MosaicGrid.columns(3, portrait = false))
    }

    @Test
    fun tilesFillTheCanvasInReadingOrderAndTheShortRowEndsEarly() {
        val rects = MosaicGrid.rects(3, portrait = false)

        assertEquals(3, rects.size)
        assertEquals(0.5, rects[1].x, 0.0)
        assertEquals(0.0, rects[1].y, 0.0)
        assertEquals(0.0, rects[2].x, 0.0)
        assertEquals(0.5, rects[2].y, 0.0)
    }

    @Test
    fun oneOrTenSourcesAreNotAMosaic() {
        assertNull(MosaicGrid.layout(sources.take(1), phone, null))
        assertNull(MosaicGrid.layout(List(10) { CaptureSource.Window(it.toLong()) }, phone, null))
    }

    @Test
    fun theCanvasIsEvenAndWithinThePixelBudget() {
        val layout = MosaicGrid.layout(sources, PixelSize(3841.0, 2161.0), null)!!

        assertTrue(layout.canvas.width % 2 == 0.0 && layout.canvas.height % 2 == 0.0)
        assertTrue(layout.canvas.width * layout.canvas.height <= 2560.0 * 1440.0)
        assertEquals(MosaicGrid.DEFAULT_FRAME_RATE, layout.frameRate)
    }

    @Test
    fun theTileShapeIsTheMedianOfWhatTheCatalogueDescribes() {
        val catalog = CaptureCatalog(windows = listOf(window(1, 1000.0, 1000.0), window(2, 2000.0, 1000.0), window(3, 3000.0, 1000.0)))

        val aspect = MosaicGrid.tileAspect(listOf(CaptureSource.Window(1), CaptureSource.Window(2), CaptureSource.Window(3)), catalog)

        assertEquals(2.0, aspect, 0.0)
    }

    @Test
    fun aLayoutKeepsTheSourcesInOrderAndCoversThePicture() {
        val layout = MosaicGrid.layout(sources, phone, null)!!

        assertNotNull(layout.tileIndexAt(NormalizedPoint(0.99, 0.99)))
        assertEquals(sources, layout.tiles.map { it.source })
    }

    private fun window(id: Long, width: Double, height: Double) = CaptureSourceDescriptor(
        id = "window:$id",
        kind = CaptureSourceKind.WINDOW,
        title = "Window $id",
        source = CaptureSource.Window(id),
        pixelSize = PixelSize(width, height),
    )
}
